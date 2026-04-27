# Example: Enterprise Materialize Deployment on Azure with Ory (OIDC/SAML)

This example extends the [simple deployment](../simple/) with **Ory Kratos** (identity management) and **Ory Hydra** (OAuth2/OIDC provider) for enterprise authentication via OIDC and SAML.

---

## What Gets Created

Everything from the [simple example](../simple/README.md), plus:

### Ory Database
- **Azure PostgreSQL Flexible Server** (separate instance from Materialize): Version 15
- **SKU**: B_Standard_B1ms (burstable, suitable for Ory workloads)
- **Databases**: `kratos` and `hydra` on the same server
- **Network Access**: Private only, same subnet as the Materialize database

### Ory Kratos (Identity Management)
- **Helm release**: Deployed in the `ory` namespace
- **Replicas**: 2 (with PodDisruptionBudget)
- **Resources**: 250m CPU request / 256Mi memory (request & limit)
- **Purpose**: Manages user identities, login/registration flows, supports OIDC and SAML providers

### Ory Hydra (OAuth2 & OIDC Provider)
- **Helm release**: Deployed in the `ory` namespace (shared with Kratos)
- **Replicas**: 2 (with PodDisruptionBudget)
- **Resources**: 250m CPU request / 256Mi memory (request & limit)
- **Maester**: Enabled (CRD controller for managing OAuth2 clients via Kubernetes resources)
- **Purpose**: Issues OAuth2 tokens, provides OIDC discovery endpoint, delegates login/consent to Kratos

---

## Getting Started

### Step 1: Set Required Variables

Create a `terraform.tfvars` file:

```hcl
subscription_id     = "12345678-1234-1234-1234-123456789012"
resource_group_name = "materialize-enterprise-rg"
name_prefix         = "enterprise-demo"
location            = "westus2"
license_key         = "your-materialize-license-key"

# OEL image pull credentials (see Materialize sales for access to Ory's
# private registry while the Materialize-hosted mirror is in flight).
ory_oel_registry = "europe-docker.pkg.dev/ory-artifacts"
ory_oel_key_file = "/path/to/ory-artifacts-sa-key.json"

# Public hostnames used for browser traffic and OIDC redirects. These must
# resolve to the LB IPs after apply (see "DNS records" below).
ory_hydra_hostname           = "hydra.mz.example.com"
ory_ui_hostname              = "auth.mz.example.com"
ory_kratos_hostname          = "kratos.mz.example.com"
materialize_console_hostname = "console.mz.example.com"

tags = {
  environment = "demo"
}
```

**Required Variables:**
- `subscription_id`: Azure subscription ID
- `resource_group_name`: Name for the resource group (will be created)
- `name_prefix`: Prefix for all resource names
- `tags`: Map of tags to apply to resources
- `license_key`: Materialize license key
- `ory_oel_registry`: Base registry URL for the Ory Enterprise License (OEL) images
- `ory_oel_key_file`: Path to a service-account key file with read access to `ory_oel_registry`
- `ory_hydra_hostname`, `ory_ui_hostname`, `ory_kratos_hostname`, `materialize_console_hostname`: Public hostnames for the four browser-facing services

**Optional Variables:**
- `location`: Azure region for deployment (defaults to `westus2`)
- `k8s_apiserver_authorized_networks`: List of authorized IP ranges for AKS API server access (defaults to `["0.0.0.0/0"]`)
- `ingress_cidr_blocks`: List of CIDR blocks allowed to reach the LoadBalancer frontends (no effect when `internal_load_balancer = true`)
- `internal_load_balancer`: Whether to use an internal load balancer (defaults to `true`). Set to `false` for prod-like demos validated against real DNS.
- `enable_observability`: Enable Prometheus and Grafana monitoring stack (defaults to `false`)
- TLS certificate options (`enable_letsencrypt`, `cert_issuer_ref`, …): see [TLS Certificates](#tls-certificates) below.

### Step 2: Deploy

```bash
terraform init
terraform apply
```

### Step 3: Verify Ory Deployment

```bash
# Check Ory pods
kubectl get pods -n ory

# Check Kratos health
kubectl port-forward svc/kratos-admin 4434:4434 -n ory
curl http://localhost:4434/health/ready

# Check Hydra health
kubectl port-forward svc/hydra-admin 4445:4445 -n ory
curl http://localhost:4445/health/ready
```

---

## TLS Certificates

cert-manager provisions every TLS certificate in this stack (Materialize console / balancerd / internal, Hydra, Kratos, selfservice UI). The example offers three issuer modes; only one is active per apply.

### Default — self-signed (demo / air-gapped)

No tfvars required. The example creates an in-cluster self-signed `ClusterIssuer` and a root CA. **Browsers will not trust the cert** and the user will see warnings.

This mode also requires environmentd to trust the cluster CA when fetching JWKS from Hydra. Patch the Materialize CR (or set this in your TF):

```yaml
spec:
  environmentdExtraEnv:
    - name: SSL_CERT_FILE
      value: /etc/materialized/ca.crt
```

Use this mode for offline demos or air-gapped clusters where no real domain or DNS provider is available.

### Let's Encrypt — recommended for prod-like demos

Set the following tfvars:

```hcl
enable_letsencrypt           = true
letsencrypt_email            = "you@example.com"
letsencrypt_acme_environment = "staging"   # flip to "production" once stable
letsencrypt_dns_provider     = "cloudflare"
letsencrypt_dns_zones        = ["example.com"]
cloudflare_api_token         = "..."
```

The example provisions a `ClusterIssuer` that satisfies ACME `dns-01` challenges via Cloudflare. Certs are browser-trusted; no `SSL_CERT_FILE` patch needed.

**Cloudflare token setup:**

1. Add your domain to Cloudflare DNS (the apex zone, e.g. `example.com`).
2. Visit https://dash.cloudflare.com/profile/api-tokens → Create Token → "Edit zone DNS" template.
3. Permissions: `Zone:DNS:Edit`, `Zone:Zone:Read`. Zone Resources: limit to the zones in `letsencrypt_dns_zones`.
4. Put the token into `cloudflare_api_token` in your tfvars (the file is gitignored).

**Staging vs. production:**

Default is `staging` to avoid burning the production rate-limit budget (50 certs/week per registered domain) while iterating. Staging certs come from an untrusted CA so browsers warn. Switch `letsencrypt_acme_environment = "production"` once DNS, hostnames, and rotation behavior are settled.

**DNS records (after `terraform apply`):**

Read the LB IPs from `terraform output` (or `kubectl get svc -A`) and create A records in Cloudflare for the four hostnames you set in tfvars (`ory_hydra_hostname`, `ory_ui_hostname`, `ory_kratos_hostname`, `materialize_console_hostname`). cert-manager issues certs once DNS resolves (1–2 min for the first issuance).

### Bring your own — corporate CA, existing Let's Encrypt setup, …

Set:

```hcl
cert_issuer_ref = {
  name = "your-existing-cluster-issuer"
  kind = "ClusterIssuer"  # or "Issuer"
}
```

Both `enable_letsencrypt` and the self-signed default are skipped; nothing is provisioned by this example. Useful when an existing `ClusterIssuer` is already in the cluster (e.g. backed by your corporate PKI, trust-manager, or a cluster-scoped Let's Encrypt setup).

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      AKS Cluster                        │
│                                                         │
│  ┌─────────────────────┐  ┌──────────────────────────┐  │
│  │   Generic Nodes     │  │  Materialize Nodes       │  │
│  │                     │  │  (tainted)               │  │
│  │  ┌───────────────┐  │  │  ┌────────────────────┐  │  │
│  │  │  Ory Kratos   │  │  │  │  Materialize       │  │  │
│  │  │  (identity)   │  │  │  │  Instance           │  │  │
│  │  ├───────────────┤  │  │  └────────────────────┘  │  │
│  │  │  Ory Hydra    │  │  │                          │  │
│  │  │  (OAuth2)     │  │  │                          │  │
│  │  ├───────────────┤  │  │                          │  │
│  │  │  Operator     │  │  │                          │  │
│  │  │  cert-manager │  │  │                          │  │
│  │  └───────────────┘  │  │                          │  │
│  └─────────────────────┘  └──────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │                           │
    ┌────┴────┐                ┌─────┴─────┐
    │ Ory DB  │                │   MZ DB   │
    │ (B1ms)  │                │ (D2s_v3)  │
    │ kratos  │                │materialize│
    │ hydra   │                │           │
    └─────────┘                └───────────┘
```

---

## Notes

- Ory Kratos and Hydra share a namespace (`ory`) but use separate databases on the same Postgres instance
- The Ory Postgres instance uses a smaller SKU (`B_Standard_B1ms`) since Ory workloads are lightweight
- Both Ory components are scheduled on generic nodes (not the Materialize-dedicated node pool)
- For production, configure identity schemas for Kratos and register OAuth2 clients in Hydra via the `helm_values` override or Hydra Maester CRDs
- Don't forget to destroy resources when finished:

```bash
terraform destroy
```
