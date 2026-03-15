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
aws_region     = "us-east-1"
aws_profile    = "default"
name_prefix    = "mz-enterprise"
license_key    = "your-materialize-license-key"
ory_issuer_url = "https://auth.example.com/"
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
- `ory_issuer_url`: The public URL where Hydra's OIDC discovery will be available

**Optional Variables:**
- `aws_region`: AWS region (defaults to `us-east-1`)
- `k8s_apiserver_authorized_networks`: List of authorized CIDR blocks for EKS API server access
- `ingress_cidr_blocks`: List of CIDR blocks allowed to reach the NLB
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
curl http://localhost:4434/admin/health/ready

# Check Hydra health
kubectl port-forward svc/hydra-admin 4445:4445 -n ory
curl http://localhost:4445/admin/health/ready
```

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
