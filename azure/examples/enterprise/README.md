# Example: Enterprise Materialize Deployment on Azure with Ory (OIDC/SAML)

This example extends the [simple deployment](../simple/) with **Ory Kratos** (identity management) and **Ory Hydra** (OAuth2/OIDC provider) for enterprise authentication via OIDC and SAML.

> **Status: work in progress.** This example currently uses an Ory OEL service-account key file to pull images and is expected to evolve before the feature is generally available. The auth mechanism will be replaced with the Materialize-hosted registry proxy once it ships.

---

## What Gets Created

Everything from the [simple example](../simple/README.md), plus:

### Ory Database
- **Azure PostgreSQL Flexible Server** (separate instance from Materialize): Version 18
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
- `k8s_apiserver_authorized_networks`: List of CIDR blocks allowed to reach the AKS API server. No default; pass `["0.0.0.0/0"]` for lab use, or a tight allowlist for production.
- `ory_oel_registry`: Base registry URL for the Ory Enterprise License (OEL) images
- `ory_oel_key_file`: Path to a service-account key file with read access to `ory_oel_registry`
- `ory_hydra_hostname`, `ory_ui_hostname`, `ory_kratos_hostname`, `materialize_console_hostname`: Public hostnames for the four browser-facing services

**Optional Variables:**
- `location`: Azure region for deployment (defaults to `westus2`)
- `ingress_cidr_blocks`: List of CIDR blocks allowed to reach the LoadBalancer frontends (no effect when `internal_load_balancer = true`)
- `internal_load_balancer`: Whether to use an internal load balancer (defaults to `true`). Set to `false` for prod-like demos validated against real DNS.
- `enable_observability`: Enable Prometheus and Grafana monitoring stack (defaults to `true`)
- TLS certificate options (`cert_issuer_ref`, …): see [TLS Certificates](#tls-certificates) below.

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

cert-manager provisions every TLS certificate in this stack. The example uses two issuers:

- An always-created in-cluster **self-signed** `ClusterIssuer` for the internal mTLS cert (which has `*.cluster.local` SANs that public ACME issuers like Let's Encrypt cannot sign).
- A configurable issuer for the browser-facing certs (Materialize console / balancerd, Hydra, Kratos, selfservice UI). Defaults to the same self-signed issuer; override via `var.cert_issuer_ref` to plug in a real one (corporate CA, Let's Encrypt, etc.).

### Default: self-signed for everything (demo / air-gapped)

No tfvars required. **Browsers will not trust the cert** and users will see warnings.

This mode requires environmentd to trust the cluster CA when fetching JWKS from Hydra. Patch the Materialize CR (or set this through the `materialize-instance` module):

```yaml
spec:
  environmentdExtraEnv:
    - name: SSL_CERT_FILE
      value: /etc/materialized/ca.crt
```

Use this mode for offline demos or air-gapped clusters where no real domain or DNS provider is available.

### Bring your own browser-facing issuer

Set:

```hcl
cert_issuer_ref = {
  name = "your-existing-cluster-issuer"
  kind = "ClusterIssuer"  # or "Issuer"
}
```

The browser-facing certs use this issuer; the internal mTLS cert continues to use the self-signed cluster issuer. Customers typically bring a corporate CA, an existing trust-manager bundle, or an ACME issuer (Let's Encrypt) backed by their preferred DNS-01 / HTTP-01 solver.

#### Example: Let's Encrypt with Cloudflare DNS-01

If you don't already have a `ClusterIssuer` in the cluster, here's a copyable starting point. Drop into your root module, customize, then point `cert_issuer_ref` at it. The same pattern works with any cert-manager solver: swap the `solvers` block for Route53, Azure DNS, Cloud DNS, HTTP-01, etc.

```hcl
# Cloudflare API token with Zone:Read + DNS:Edit on the zones you'll request
# certs for. Create at https://dash.cloudflare.com/profile/api-tokens.
variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

resource "kubernetes_secret_v1" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "cert-manager"
  }
  data = {
    "api-token" = var.cloudflare_api_token
  }
}

resource "kubectl_manifest" "letsencrypt_prod" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        # While iterating, point at the staging server to avoid the production
        # rate limit (50 certs / week / registered domain). Staging certs are
        # not browser-trusted; switch back once the integration is stable.
        # server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = "you@example.com"
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [{
          selector = {
            dnsZones = ["example.com"]
          }
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = kubernetes_secret_v1.cloudflare_api_token.metadata[0].name
                key  = "api-token"
              }
            }
          }
        }]
      }
    }
  })

  depends_on = [kubernetes_secret_v1.cloudflare_api_token]
}

module "materialize_enterprise" {
  source = "..."

  cert_issuer_ref = {
    name = "letsencrypt-prod"
    kind = "ClusterIssuer"
  }

  # ...rest of the example variables
}
```

After `terraform apply`, create A records for your hostnames (Hydra, Kratos, selfservice UI, Materialize console) pointing at the LB IPs. cert-manager issues certs once DNS resolves (typically 1 to 2 minutes for the first issuance).

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
- For production, override Kratos and Hydra chart values via `kratos_helm_values` and `hydra_helm_values` on the `module.ory` call (they deep-merge on top of the baked-in defaults), and register additional OAuth2 clients via Hydra Maester CRDs (Maester is enabled by default)
- Don't forget to destroy resources when finished:

```bash
terraform destroy
```

---

## Limitations

### OEL registry credentials in Terraform state

The ory-stack module reads `var.ory_oel_key_file` via `file()` at plan time and embeds the decoded JSON service-account key into a Kubernetes secret in the `ory` namespace. Terraform stores that value in plaintext in the state file. Anyone with read access to the state backend (Azure Blob, S3, the local `terraform.tfstate`) can extract working GCP credentials for Ory's Artifact Registry.

Treat the state file as a secret. The planned replacement is the Materialize-hosted OEL mirror, which authenticates against a registry proxy using the license-key JWT (no shared service-account key on disk). Migrate to that path once it ships.

### Resource-group destroy guard

This example sets `prevent_deletion_if_contains_resources = true` on the `azurerm` provider, so `terraform destroy` refuses to delete the resource group while it still has children. This protects you from a destroy run that would silently take down databases, storage, and cluster state. To actually tear the stack down, destroy the contents first (or temporarily flip the flag to `false` and re-apply before destroying).

### Key Vault soft-delete

This example sets `purge_soft_delete_on_destroy = false` and `recover_soft_deleted_key_vaults = true`. After a `terraform destroy` the Key Vault enters a 90-day soft-deleted retention window instead of being purged immediately. A subsequent `terraform apply` with the same name will try to recover the soft-deleted vault rather than fail. If you really need to reuse the name on a fresh vault, purge it manually:

```bash
az keyvault purge --name <vault-name> --location <location>
```

For lab iteration where you do not care about recovery, you can flip `purge_soft_delete_on_destroy = true` in the `azurerm` provider block.

### Balancerd SAN

This example only puts `materialize_console_hostname` into the **console** cert SAN list. Balancerd (the SQL wire-protocol endpoint) sits behind its own LoadBalancer and is not exposed under a public hostname by default. If you want external SQL access, register a separate hostname, create an A record for it pointing at the balancerd LB IP, and add it to the `balancerd_extra_dns_names` argument of the `materialize_instance` module call in `main.tf`.
