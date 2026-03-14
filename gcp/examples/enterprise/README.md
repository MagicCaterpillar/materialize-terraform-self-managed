# Example: Enterprise Materialize Deployment on GCP with Ory (OIDC/SAML)

This example extends the [simple deployment](../simple/) with **Ory Kratos** (identity management) and **Ory Hydra** (OAuth2/OIDC provider) for enterprise authentication via OIDC and SAML.

---

## What Gets Created

Everything from the [simple example](../simple/README.md), plus:

### Ory Database
- **Cloud SQL for PostgreSQL** (separate instance from Materialize): Version 15
- **Tier**: db-f1-micro (suitable for Ory workloads)
- **Databases**: `kratos` and `hydra` on the same instance
- **Network Access**: Private IP only, same VPC as the Materialize database

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
project_id     = "my-gcp-project-id"
region         = "us-central1"
name_prefix    = "mz-enterprise"
license_key    = "your-materialize-license-key"
ory_issuer_url = "https://auth.example.com/"
labels = {
  environment = "demo"
  project     = "materialize-enterprise"
}
```

**Required Variables:**
- `project_id`: GCP project ID
- `labels`: Map of labels to apply to resources
- `ory_issuer_url`: The public URL where Hydra's OIDC discovery will be available

**Optional Variables:**
- `region`: GCP region (defaults to `us-central1`)
- `name_prefix`: Prefix for all resource names (defaults to `materialize`)
- `license_key`: Materialize license key
- `k8s_apiserver_authorized_networks`: List of authorized CIDR blocks for GKE API server access
- `ingress_cidr_blocks`: List of CIDR blocks allowed to reach the Load Balancer
- `internal_load_balancer`: Whether to use an internal load balancer (defaults to `true`)
- `enable_observability`: Enable Prometheus and Grafana monitoring stack (defaults to `false`)

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

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      GKE Cluster                        │
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
    │(f1-micro│                │(custom-2) │
    │ kratos  │                │materialize│
    │ hydra   │                │           │
    └─────────┘                └───────────┘
```

---

## Notes

- Ory Kratos and Hydra share a namespace (`ory`) but use separate databases on the same Cloud SQL instance
- The Ory Cloud SQL instance uses a smaller tier (`db-f1-micro`) since Ory workloads are lightweight
- Both Ory components are scheduled on generic nodes (not the Materialize-dedicated node pool)
- Cloud SQL on GCP has PostgreSQL extensions (pg_trgm, btree_gin, uuid-ossp) available by default — no allowlisting needed
- For production, configure identity schemas for Kratos and register OAuth2 clients in Hydra via the `helm_values` override or Hydra Maester CRDs
- Don't forget to destroy resources when finished:

```bash
terraform destroy
```
