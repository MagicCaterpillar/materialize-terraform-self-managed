use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use tokio::process::Command;

use crate::helpers::{
    ci_log_group, kubectl, read_tfvars, retry, run_cmd, run_cmd_output, write_lifecycle,
};
use crate::types::{CloudProvider, TerraformOutputs, TfVars};

/// Runs verification commands against an applied test environment.
pub async fn phase_verify(dir: &Path) -> Result<()> {
    ci_log_group("Verify", || async {
        write_lifecycle(dir, "verify", "started").await?;
        let tfvars = read_tfvars(dir)?;
        let provider = tfvars.cloud_provider();
        println!("Verifying test run...");

        let outputs_raw = run_cmd_output(
            Command::new("terraform")
                .args(["output", "-json"])
                .current_dir(dir),
        )
        .await
        .context("terraform output failed")?;

        let outputs: TerraformOutputs =
            serde_json::from_str(&outputs_raw).context("Failed to parse terraform output JSON")?;

        let instance_namespace = &outputs.materialize_instance_namespace.value;
        let instance_name = &outputs.materialize_instance_name.value;

        println!("\nConfiguring kubectl...");
        let kubeconfig = setup_kubeconfig(dir, provider, &tfvars, &outputs).await?;

        println!("\nVerifying Materialize instance...");
        verify_materialize_instance(&kubeconfig, instance_namespace, instance_name).await?;

        println!("\nVerifying pods in namespace {instance_namespace}...");
        verify_pods_running(&kubeconfig, instance_namespace).await?;

        if let Some(endpoint) = outputs.load_balancer_endpoint() {
            println!("\nVerifying Materialize SQL connectivity at {endpoint}...");
            verify_sql_connection(endpoint, &outputs).await?;
        } else {
            println!("\nSkipping SQL connectivity check (no load balancer endpoint found).");
        }

        write_lifecycle(dir, "verify", "completed").await?;
        println!("\nAll verifications passed!");
        Ok(())
    })
    .await
}

async fn setup_kubeconfig(
    dir: &Path,
    provider: CloudProvider,
    tfvars: &TfVars,
    outputs: &TerraformOutputs,
) -> Result<PathBuf> {
    let kubeconfig = dir.join("kubeconfig");
    let cluster_name = outputs.cluster_name(provider)?;
    match tfvars {
        TfVars::Aws {
            aws_region,
            aws_profile,
            ..
        } => {
            run_cmd(
                Command::new("aws")
                    .args([
                        "eks",
                        "update-kubeconfig",
                        "--name",
                        cluster_name,
                        "--region",
                        aws_region,
                        "--profile",
                        aws_profile,
                    ])
                    .env("KUBECONFIG", &kubeconfig),
            )
            .await?;
        }
        TfVars::Gcp {
            region, project_id, ..
        } => {
            run_cmd(
                Command::new("gcloud")
                    .args([
                        "container",
                        "clusters",
                        "get-credentials",
                        cluster_name,
                        "--region",
                        region,
                        "--project",
                        project_id,
                    ])
                    .env("KUBECONFIG", &kubeconfig),
            )
            .await?;
        }
        TfVars::Azure {
            resource_group_name,
            ..
        } => {
            run_cmd(
                Command::new("az")
                    .args([
                        "aks",
                        "get-credentials",
                        "--resource-group",
                        resource_group_name,
                        "--name",
                        cluster_name,
                        "--overwrite-existing",
                    ])
                    .env("KUBECONFIG", &kubeconfig),
            )
            .await?;
        }
    }
    println!("  Wrote {}", kubeconfig.display());
    Ok(kubeconfig)
}

async fn verify_materialize_instance(kubeconfig: &Path, namespace: &str, name: &str) -> Result<()> {
    let result = run_cmd(kubectl(kubeconfig).args([
        "wait",
        "--for=jsonpath={.status.conditions[?(@.type==\"UpToDate\")].status}=True",
        &format!("materialize/{name}"),
        "-n",
        namespace,
        "--timeout=600s",
    ]))
    .await;

    if let Err(e) = result {
        dump_materialize_diagnostics(kubeconfig, namespace, name).await;
        return Err(e).context("Materialize instance did not become UpToDate within timeout");
    }

    println!("  Materialize instance {name} is UpToDate.");
    Ok(())
}

/// Best-effort diagnostic dump when verify_materialize_instance times out.
/// Each command's failure is logged but ignored so we always get the rest of
/// the output even if one section errors.
async fn dump_materialize_diagnostics(kubeconfig: &Path, namespace: &str, name: &str) {
    println!("\n--- diagnostics: Materialize CR did not become UpToDate ---");

    async fn run_section(label: &str, kubeconfig: &Path, args: &[&str]) {
        println!("\n>>> {label}");
        if let Err(e) = run_cmd(kubectl(kubeconfig).args(args)).await {
            println!("(diagnostic command failed: {e:#})");
        }
    }

    let materialize_ref = format!("materialize/{name}");
    run_section(
        "kubectl describe materialize",
        kubeconfig,
        &["describe", &materialize_ref, "-n", namespace],
    )
    .await;
    run_section(
        "kubectl get pods (instance namespace)",
        kubeconfig,
        &["get", "pods", "-n", namespace, "-o", "wide"],
    )
    .await;
    run_section(
        "kubectl get pods (operator namespace)",
        kubeconfig,
        &["get", "pods", "-n", "materialize", "-o", "wide"],
    )
    .await;
    run_section(
        "kubectl logs (materialize-operator, last 300 lines)",
        kubeconfig,
        &[
            "logs",
            "-n",
            "materialize",
            "-l",
            "app.kubernetes.io/name=materialize-operator",
            "--tail=300",
            "--all-containers",
        ],
    )
    .await;
    run_section(
        "kubectl describe pods (instance namespace)",
        kubeconfig,
        &["describe", "pods", "-n", namespace],
    )
    .await;
    run_section(
        "kubectl get networkpolicy (all namespaces)",
        kubeconfig,
        &["get", "networkpolicy", "-A", "-o", "yaml"],
    )
    .await;
    run_section(
        "kubectl get svc,endpoints (instance namespace)",
        kubeconfig,
        &["get", "svc,endpoints", "-n", namespace, "-o", "wide"],
    )
    .await;

    // Probe environmentd:6876 from a pod scheduled into the operator namespace.
    // That pod inherits the same egress NetworkPolicies as the orchestratord, so
    // the curl exit / verbose output disambiguates the failure mode (timeout =>
    // NetworkPolicy or SG drop; refused => no listener; TLS error => cert
    // mismatch). Best-effort; if anything in the probe fails we just log and
    // move on.
    if let Ok(resource_id) = run_cmd_output(kubectl(kubeconfig).args([
        "get",
        &format!("materialize/{name}"),
        "-n",
        namespace,
        "-o",
        "jsonpath={.status.resourceId}",
    ]))
    .await
        && !resource_id.is_empty()
    {
        let target = format!(
            "https://mz{resource_id}-environmentd-1.{namespace}.svc.cluster.local:6876/api/login"
        );
        let probe_name = format!("verify-probe-{resource_id}");
        println!("\n>>> curl probe from operator namespace -> {target}");
        if let Err(e) = run_cmd(kubectl(kubeconfig).args([
            "run",
            &probe_name,
            "--rm",
            "--restart=Never",
            "-i",
            "--image=curlimages/curl:latest",
            "--namespace=materialize",
            "--command",
            "--",
            "curl",
            "-v",
            "-k",
            "--max-time",
            "15",
            &target,
        ]))
        .await
        {
            println!("(probe failed: {e:#})");
        }
    }

    println!("\n--- end diagnostics ---");
}

/// The expected pod types and their minimum counts in the materialize namespace.
const EXPECTED_PODS: &[(&str, usize)] = &[
    ("environmentd", 1),
    ("console", 2),
    ("balancerd", 2),
    ("cluster-u1", 1),
    ("cluster-s2", 1),
];

async fn verify_pods_running(kubeconfig: &Path, namespace: &str) -> Result<()> {
    const MAX_ATTEMPTS: u32 = 60;
    const INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

    retry(
        MAX_ATTEMPTS,
        INTERVAL,
        |attempt, err| {
            println!(
                "  Attempt {attempt}/{MAX_ATTEMPTS}: {err:#}, retrying in {}s...",
                INTERVAL.as_secs()
            );
        },
        || check_expected_pods(kubeconfig, namespace),
    )
    .await
    .context("Not all expected pods became Running within timeout")?;

    println!("  All expected pods are running.");
    Ok(())
}

async fn check_expected_pods(kubeconfig: &Path, namespace: &str) -> Result<()> {
    let output = run_cmd_output(kubectl(kubeconfig).args([
        "get",
        "pods",
        "-n",
        namespace,
        "-o",
        "jsonpath={range .items[*]}{.metadata.name} {.status.phase}{'\\n'}{end}",
    ]))
    .await?;

    let pods: Vec<(&str, &str)> = output
        .lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 {
                Some((parts[0], parts[1]))
            } else {
                None
            }
        })
        .collect();

    for &(pod_type, min_count) in EXPECTED_PODS {
        let running = pods
            .iter()
            .filter(|(name, phase)| name.contains(pod_type) && *phase == "Running")
            .count();
        if running < min_count {
            bail!("expected at least {min_count} running {pod_type} pod(s), found {running}");
        }
    }

    for (name, phase) in &pods {
        println!("  [ok] {name}: {phase}");
    }
    Ok(())
}

async fn verify_sql_connection(endpoint: &str, outputs: &TerraformOutputs) -> Result<()> {
    let password = outputs.mz_password()?;

    const MAX_ATTEMPTS: u32 = 20;
    const INTERVAL: std::time::Duration = std::time::Duration::from_secs(15);

    let output = retry(
        MAX_ATTEMPTS,
        INTERVAL,
        |attempt, _| {
            println!(
                "  Attempt {attempt}/{MAX_ATTEMPTS} failed, retrying in {}s...",
                INTERVAL.as_secs()
            );
        },
        || async {
            run_cmd_output(
                Command::new("psql")
                    .args([
                        "-h",
                        endpoint,
                        "-p",
                        "6875",
                        "-U",
                        "mz_system",
                        "-d",
                        "materialize",
                        "-c",
                        "SELECT 1",
                    ])
                    .env("PGPASSWORD", password)
                    .env("PGCONNECT_TIMEOUT", "30")
                    .env("PGSSLMODE", "require"),
            )
            .await
        },
    )
    .await
    .context("Failed to connect to Materialize via SQL after all retries")?;

    println!("  SQL query succeeded: {output}");
    Ok(())
}
