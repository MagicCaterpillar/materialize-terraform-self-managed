# Materialize Self-Managed Terraform Modules

---

## About Materialize

Materialize is a real-time data integration platform that creates and continually updates consistent views of transactional data from across your organization. Its SQL interface democratizes the ability to serve and access live data. Materialize can be deployed anywhere your infrastructure runs.

Use Materialize to do things like deliver fresh context for AI/RAG pipelines, power operational dashboards, and create more dynamic customer experiences without building time-consuming custom data pipelines.

The three most common patterns for adopting Materialize are the following:

Query Offload (CQRS) - Scale complex read queries more efficiently than a read replica, and without the headaches of cache invalidation.
Integration Hub (ODS) - Extract, load, and incrementally transform data from multiple sources. Create live views of your data that can be queried directly or pushed downstream.
Operational Data Mesh (ODM) - Use SQL to create and deliver real-time, strongly consistent data products to streamline coordination across services and domains.

---

## Overview

This repository provides production-ready Terraform modules for deploying Materialize in self-managed environments across AWS, Azure, and Google Cloud Platform. The modules are designed to be composable, allowing you to use them individually or combine them to build complete infrastructure stacks.

### Architecture

A typical Materialize deployment consists of:

**Cloud Infrastructure Layer:**
- **Networking**: VPC/VNet with private and public subnets, NAT gateways, and network security
- **Kubernetes Cluster**: Managed Kubernetes service (EKS, AKS, or GKE) with autoscaling node groups
- **Metadata Store**: Managed PostgreSQL database for Materialize system catalog and metadata
- **Object Storage**: S3/Blob Storage/GCS for Materialize's persistent data layer
- **Load Balancing**: Cloud-native load balancers for exposing Materialize services

**Kubernetes Application Layer:**
- **Materialize Operator**: Kubernetes operator that manages Materialize instances
- **Cert-Manager**: Certificate management for TLS
- **Materialize Instance**: The actual Materialize deployment with configurable resources

### Repository Structure

```
├── aws/                    # AWS-specific infrastructure modules
│   ├── modules/           # Reusable AWS modules (VPC, EKS, RDS, S3, etc.)
│   └── examples/simple/   # Complete AWS deployment example
├── azure/                  # Azure-specific infrastructure modules
│   ├── modules/           # Reusable Azure modules (VNet, AKS, PostgreSQL, Storage, etc.)
│   └── examples/simple/   # Complete Azure deployment example
├── gcp/                    # GCP-specific infrastructure modules
│   ├── modules/           # Reusable GCP modules (VPC, GKE, CloudSQL, GCS, etc.)
│   └── examples/simple/   # Complete GCP deployment example
├── kubernetes/             # Cloud-agnostic Kubernetes modules
│   └── modules/           # Cert-manager, Materialize instance, etc.
└── test/                   # Terratest integration tests
```

---

## Cloud Provider Support

### AWS

Complete support for deploying Materialize on Amazon Web Services with EKS, RDS PostgreSQL, and S3.

**Key Features:**
- EKS cluster with **Karpenter** for advanced node autoscaling and efficient resource management
- RDS PostgreSQL for metadata storage
- S3 with IRSA for secure, passwordless access
- Network Load Balancer for service exposure
- Multi-AZ deployment support

**Autoscaling:** Uses [Karpenter](https://karpenter.sh/docs/), to provision right-sized nodes based on pending pod requirements, offering better bin-packing and faster scale-up compared to cluster autoscaler.

**Get Started:** See [aws/examples/simple/README.md](./aws/examples/simple/README.md) for detailed deployment instructions and architecture.

### Azure

Complete support for deploying Materialize on Microsoft Azure with AKS, Azure Database for PostgreSQL, and Azure Storage.

**Key Features:**
- AKS cluster with Cilium networking
- PostgreSQL Flexible Server for metadata storage
- Azure Storage with Workload Identity federation for secure access
- Azure Load Balancer for service exposure
- Multi-zone deployment support

**Autoscaling:** Uses Azure's native cluster autoscaler that integrates directly with Azure Virtual Machine Scale Sets for automated node scaling. In future we are planning to enhance this by making use of [karpenter-provider-azure](https://github.com/Azure/karpenter-provider-azure)

**Get Started:** See [azure/examples/simple/README.md](./azure/examples/simple/README.md) for detailed deployment instructions and architecture.

### GCP

Complete support for deploying Materialize on Google Cloud Platform with GKE, Cloud SQL, and Cloud Storage.

**Key Features:**
- GKE cluster with Workload Identity
- Cloud SQL PostgreSQL for metadata storage
- Cloud Storage with HMAC keys for S3-compatible access
- GCP Load Balancer for service exposure
- Regional deployment support

**Autoscaling:** Uses GKE's native cluster autoscaler that integrates with Google Compute Engine managed instance groups for automated node scaling.

**Get Started:** See [gcp/examples/simple/README.md](./gcp/examples/simple/README.md) for detailed deployment instructions and architecture.

---

## Unsupported Features & Known Limitations

### GCP Storage Authentication

**Limitation:** Materialize currently only supports HMAC key authentication for GCS access (S3-compatible API).

**Current State:** The modules configure both HMAC keys and Workload Identity, but Materialize uses HMAC keys for actual storage access.

**Future:** Native GCS access via Workload Identity Federation or Kubernetes service account impersonation will be supported in a future release, eliminating the need for static credentials.

---

## Getting Started

### Prerequisites

- Terraform >= 1.0
- Cloud provider credentials configured
- kubectl (for managing Kubernetes resources)
- Appropriate cloud provider CLI tools (aws-cli, az, or gcloud)

### Quick Start

1. **Choose your cloud provider** and navigate to the example directory
2. **Review the example README** for cloud-specific prerequisites and configuration
3. **Set required variables** in a `terraform.tfvars` file
4. **Deploy the infrastructure:**

```bash
cd <cloud-provider>/examples/simple
terraform init
terraform plan
terraform apply
```

4. **Connect to your Materialize instance** using the connection details from the Terraform outputs

### Module Usage

All modules can be used independently. For example, if you already have a Kubernetes cluster, you can use just the Materialize-specific modules:

```hcl
module "materialize_instance" {
  source               = "github.com/MaterializeInc/materialize-terraform-self-managed//kubernetes/modules/materialize-instance"
  instance_name        = "production"
  instance_namespace   = "materialize"
  metadata_backend_url = "postgres://user:pass@host/db"
  persist_backend_url  = "s3://bucket-name/prefix"
  # ... additional configuration
}
```

### SQL Server Local Access (Private)

In order to connect to SQL server from the local machine, port forwarding is used through the command `kubectl port-forward`.

Use the helper script:

```powershell
./sql-server/scripts/connect-local-sqlserver.ps1
```

What it does:
- Starts a localhost-only tunnel (`127.0.0.1:<local-port> -> sql-server service:1433`)
- Optionally runs a SQL login/query health check
- Prints SSMS/HammerDB connection settings
- Stops the tunnel when you press Enter

Manual equivalent:

```powershell
kubectl port-forward svc/mssql -n sql-server 11433:1433 --address 127.0.0.1
```

Then connect from SSMS/HammerDB to:
- Server: `127.0.0.1,11433`
- Login: `SA`
- Password: `terraform -chdir="sql-server/examples/azure" output -raw sa_password`
- Encrypt: `True`
- Trust Server Certificate: `True`

---

## Development & Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for development setup, testing instructions, and contribution guidelines.

### Documentation Generation

This project uses [terraform-docs](https://terraform-docs.io/) to auto-generate module documentation. To regenerate documentation after making changes:

```bash
.github/scripts/generate-docs.sh
```

### Testing

The repository includes comprehensive integration tests using Terratest. See [test/README.md](./test/README.md) for testing architecture and instructions.

---

## License

See [LICENSE](./LICENSE) file for details.

---

## Support

- **Documentation**: [materialize.com/docs/self-managed](https://materialize.com/docs/self-managed/)
- **Community**: [Materialize Community Slack](https://materialize.com/s/chat)
- **Issues**: [GitHub Issues](https://github.com/MaterializeInc/materialize-terraform-self-managed/issues)
