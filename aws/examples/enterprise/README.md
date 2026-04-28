# Example: Enterprise Materialize Deployment on AWS with Ory (OIDC/SAML)

This example extends the [simple deployment](../simple/) with **Ory Kratos** (identity management) and **Ory Hydra** (OAuth2/OIDC provider) for enterprise authentication via OIDC and SAML.

---

## What Gets Created

Everything from the [simple example](../simple/README.md), plus:

### Ory Databases
- **Two separate RDS instances** (one for Kratos, one for Hydra): PostgreSQL 15
- **Instance class**: db.t3.small (suitable for Ory workloads)
- **Storage**: 20GB with autoscaling up to 50GB
- **Network Access**: Private subnets only, same VPC as the Materialize database

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
aws_region  = "us-east-1"
aws_profile = "default"
name_prefix = "mz-enterprise"
license_key = "your-materialize-license-key"

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
  project     = "materialize-enterprise"
}
```

**Required Variables:**
- `aws_profile`: AWS CLI profile for authentication
- `name_prefix`: Prefix for all resource names
- `license_key`: Materialize license key
- `tags`: Map of tags to apply to resources
- `ory_oel_registry`: Base registry URL for the Ory Enterprise License (OEL) images
- `ory_oel_key_file`: Path to a service-account key file with read access to `ory_oel_registry`
- `ory_hydra_hostname`, `ory_ui_hostname`, `ory_kratos_hostname`, `materialize_console_hostname`: Public hostnames for the four browser-facing services

**Optional Variables:**
- `aws_region`: AWS region (defaults to `us-east-1`)
- `k8s_apiserver_authorized_networks`: List of authorized CIDR blocks for EKS API server access
- `ingress_cidr_blocks`: List of CIDR blocks allowed to reach the NLB (no effect when `internal_load_balancer = true`)
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
curl http://localhost:4434/admin/health/ready

# Check Hydra health
kubectl port-forward svc/hydra-admin 4445:4445 -n ory
curl http://localhost:4445/admin/health/ready
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
┌─────────────────────────────────────────────────────────────┐
│                       EKS Cluster                           │
│                                                             │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────────┐  │
│  │  Base Nodes  │  │ Generic Nodes │  │ Materialize Nodes│  │
│  │  (Karpenter, │  │ (Karpenter)   │  │ (tainted)        │  │
│  │   CoreDNS)   │  │               │  │                  │  │
│  │              │  │ ┌───────────┐ │  │ ┌──────────────┐ │  │
│  │              │  │ │ Ory Kratos│ │  │ │ Materialize  │ │  │
│  │              │  │ │ Ory Hydra │ │  │ │ Instance     │ │  │
│  │              │  │ │ Operator  │ │  │ └──────────────┘ │  │
│  │              │  │ └───────────┘ │  │                  │  │
│  └──────────────┘  └───────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────┘
    │          │            │                    │
    │    ┌─────┴─────┐ ┌───┴────┐          ┌────┴─────┐
    │    │Kratos RDS │ │Hydra   │          │  MZ RDS  │
    │    │(t3.small) │ │RDS     │          │(t3.large)│
    │    └───────────┘ │(t3.sm) │          └──────────┘
    │                  └────────┘
    │
┌───┴───┐
│  S3   │
│Bucket │
└───────┘
```

---

## Notes

- AWS RDS creates one database per instance, so Kratos and Hydra each get their own RDS instance (`db.t3.small`)
- Both Ory components share the `ory` namespace but have separate databases
- Both Ory components are scheduled on generic Karpenter nodes (not the Materialize-dedicated node pool)
- AWS RDS has PostgreSQL extensions (pg_trgm, btree_gin, uuid-ossp) available by default
- For production, configure identity schemas for Kratos and register OAuth2 clients in Hydra via the `helm_values` override or Hydra Maester CRDs
- Don't forget to destroy resources when finished:

```bash
terraform destroy
```
