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
ory_issuer_url      = "https://auth.example.com/"
tags = {
  environment = "demo"
}
```

**Required Variables:**
- `subscription_id`: Azure subscription ID
- `resource_group_name`: Name for the resource group (will be created)
- `name_prefix`: Prefix for all resource names
- `location`: Azure region for deployment
- `tags`: Map of tags to apply to resources
- `license_key`: Materialize license key
- `ory_issuer_url`: The public URL where Hydra's OIDC discovery will be available (e.g., `https://auth.example.com/`)

**Optional Variables:**
- `k8s_apiserver_authorized_networks`: List of authorized IP ranges for AKS API server access (defaults to `["0.0.0.0/0"]`)
- `ingress_cidr_blocks`: List of CIDR blocks allowed to reach the Load Balancer (defaults to `["0.0.0.0/0"]`)
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
