# Example: Simple Materialize Deployment on Azure

This example demonstrates how to deploy a complete Materialize environment on Azure using the modular Terraform setup from this repository.

---

## What Gets Created

This example provisions the following infrastructure:

### Resource Group
- **Resource Group**: New resource group to contain all resources

### Networking
- **Virtual Network**: 20.0.0.0/16 address space
- **AKS Subnet**: 20.0.0.0/20 with NAT Gateway association and service endpoints for Storage and SQL
- **PostgreSQL Subnet**: 20.0.16.0/24 delegated to PostgreSQL Flexible Server
- **NAT Gateway**: Standard SKU with static public IP for outbound connectivity
- **Private DNS Zone**: For PostgreSQL private endpoint resolution with VNet link

### Compute
- **AKS Cluster**: Version 1.34 with Cilium networking (network plugin: azure, data plane: cilium, policy: cilium)
- **Default Node Pool**: Standard_D4pds_v6 VMs, autoscaling 2-5 nodes, labeled for generic workloads
- **Materialize Node Pool**: Standard_E4pds_v6 VMs with 100GB disk, autoscaling 2-5 nodes, swap enabled, dedicated taints for Materialize workloads
- **Managed Identities**:
  - AKS cluster identity: Used by AKS control plane to provision Azure resources (creating load balancers when Materialize LoadBalancer services are created, managing network interfaces)
  - Workload identity: Used by Materialize pods for secure, passwordless authentication to Azure Storage (no storage account keys stored in cluster)

### Database
- **Azure PostgreSQL Flexible Server**: Version 15
- **SKU**: GP_Standard_D2s_v3 (2 vCores, 4GB memory)
- **Storage**: 32GB with 7-day backup retention
- **Network Access**: Public Network Access is disabled, Private access only (no public endpoint)
- **Database**: `materialize` database pre-created

### Storage
- **Storage Account**: Premium BlockBlobStorage with LRS replication for Materialize persistence
- **Container**: `materialize` blob container
- **Access Control**: Workload Identity federation for Kubernetes service account (passwordless authentication via OIDC)
- **Network Access**: Currently allows all traffic (production deployments should restrict to AKS subnet only traffic)

### Kubernetes Add-ons
- **cert-manager**: Certificate management controller for Kubernetes that automates TLS certificate provisioning and renewal
- **Self-signed ClusterIssuer**: Provides self-signed TLS certificates for Materialize instance internal communication (balancerd, console). Used by the Materialize instance for secure inter-component communication.

### Materialize
- **Operator**: Materialize Kubernetes operator
- **Instance**: Single Materialize instance in `materialize-environment` namespace
- **Load Balancers**: Internal Azure Load Balancers for Materialize access

---

## Required Features

Your Azure subscription needs certain features enabled.


```bash
# Enable the API Server VNet Integration preview feature:
# This allows the AKS API server to be placed inside your VNet for enhanced security
az feature register \
  --namespace Microsoft.ContainerService \
  --name EnableAPIServerVnetIntegrationPreview

# Check the status of the required feature:
az feature show \
  --namespace Microsoft.ContainerService \
  --name EnableAPIServerVnetIntegrationPreview
```
- Reference: https://learn.microsoft.com/en-us/azure/aks/api-server-vnet-integration#prerequisites
---

## Getting Started

### Step 1: Set Required Variables

Before running Terraform, create a `terraform.tfvars` file with the following variables:

```hcl
subscription_id     = "12345678-1234-1234-1234-123456789012"
resource_group_name = "materialize-demo-rg"
name_prefix         = "simple-demo"
location            = "westus2"
license_key         = "your-materialize-license-key"  # Optional: Get from https://materialize.com/self-managed/
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

**Optional Variables:**
- `k8s_apiserver_authorized_networks`: List of authorized IP ranges for AKS API server access (defaults to `["0.0.0.0/0"]`)
- `ingress_cidr_blocks`: List of CIDR blocks allowed to reach the Load Balancer (defaults to `["0.0.0.0/0"]`)
- `internal_load_balancer`: Whether to use an internal load balancer (defaults to `true`)

### Configuring API Server Authorized IP Ranges

To restrict AKS API server access to your IP address:

1. Get your public IP and convert to CIDR:
```bash
MY_IP=$(curl -s https://ipinfo.io/ip)
MY_IP_CIDR="${MY_IP}/32"  # Single IP, or use: whois $MY_IP | grep route
echo $MY_IP_CIDR
```

2. Add to `terraform.tfvars`:
```hcl
k8s_apiserver_authorized_networks = ["X.X.X.X/X"]  # Replace with your IP from step 1
```

**Note**: Public IP addresses may change since they are allocated by your ISP. These steps should be used in environments where the CIDR is static (e.g., corporate networks with fixed IP ranges, VPN endpoints, or static IP services). For dynamic IP environments, consider using broader CIDR ranges or alternative access methods.

### Configuring Load Balancer Ingress CIDR Blocks

To restrict Load Balancer access to specific IP ranges:

```hcl
ingress_cidr_blocks = ["203.0.113.0/24", "198.51.100.0/24"]
```

---

### Step 2: Deploy Materialize

Run the usual Terraform workflow:

```bash
terraform init
terraform apply
```

If your subscription has low vCPU quotas (for example 10 total regional vCPUs), use the low-quota profile:

```bash
terraform init
terraform apply -var-file=terraform.tfvars -var-file=terraform.low-quota.tfvars
```

This profile scales down both AKS node pools to a single smaller node each:
- Default node pool: `Standard_D2pds_v6`, autoscaling disabled, 1 node
- Materialize node pool: `Standard_E2pds_v6`, autoscaling disabled, 1 node

Once your quota increase is approved, remove the low-quota var file from the command to return to standard sizing.

Note for Windows users:
- This example keeps AKS default CoreDNS and CoreDNS autoscaler enabled to avoid bash-dependent `local-exec` steps in the CoreDNS module.
- This is intentional for cross-platform compatibility in this example.

---

### Step 3: Accessing Materialize

#### Security Model
This deployment implements a secure access model:
- **Public Access**: Only allowed via the Azure Load Balancer.
- **Direct Node Access**: **BLOCKED**. The AKS nodes are in private subnets and only accept traffic from within the VNet.

#### Access Methods

**If using a public (external) Load Balancer:**

Both SQL and Console are available via the public Load Balancer:

- **SQL Access**: Connect using any PostgreSQL-compatible client pointing to the Load Balancer's IP on port **6875**
- **Console Access**: Access the Materialize Console via the Load Balancer's IP on port **8080**

To get the Load Balancer IP:
```bash
kubectl get svc -n materialize-environment -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}'
```

**If using a private (internal) Load Balancer:**

Use Kubernetes port-forwarding for both SQL and Console. `kubectl port-forward` creates a TCP tunnel that preserves the underlying protocol (pgwire for SQL, HTTP for Console):

- **SQL Access**:
```bash
# Forward local port 6875 to the Materialize balancerd service
kubectl port-forward svc/mz<resource-id>-balancerd 6875:6875 -n materialize-environment
```
Then connect your PostgreSQL client to `localhost:6875`. The pgwire protocol is preserved through the TCP tunnel.

- **Console Access**:
```bash
# Forward local port 8080 to the Materialize console service
kubectl port-forward svc/mz<resource-id>-console 8080:8080 -n materialize-environment
```
Then open your browser to `http://localhost:8080`. HTTP traffic is preserved through the TCP tunnel.

**Note on Load Balancer Layer 4 operation:**
The Load Balancer operates at Layer 4 (TCP), forwarding connections without interpreting application-layer protocols. This works correctly for both pgwire (port 6875) and HTTP console access (port 8080), as both protocols run over TCP.

---

### Step 4: Accessing Grafana

Grafana is deployed in the `monitoring` namespace with pre-configured Materialize dashboards.

#### Port Forwarding

```bash
kubectl port-forward svc/grafana 3000:80 -n monitoring
```

Then open [http://localhost:3000](http://localhost:3000) in your browser.

#### Login Credentials

- **Username:** `admin`
- **Password:** Retrieve from Terraform output:

```bash
terraform output -raw grafana_admin_password
```

#### Pre-configured Dashboards

The deployment includes Materialize dashboards under the "kubernetes/grafana" folder:
- **Environment Overview** - Overall Materialize environment health
- **Freshness Overview** - Data freshness monitoring

---

## Prometheus Resource Sizing Recommendations

The default Prometheus resource limits (500m CPU / 512Mi memory request, 1 CPU / 1Gi memory limit) are suitable for small deployments monitoring a single Materialize environment with default scrape intervals.

For production deployments, consider increasing resources based on:
- **Number of scrape targets**: More targets = more memory for time series
- **Scrape interval**: Lower intervals increase CPU and memory usage
- **Retention period**: Longer retention requires more storage and memory
- **Query complexity**: Heavy dashboard usage increases CPU needs

Example configuration for medium workload in `main.tf`:

```hcl
module "prometheus" {
  source = "../../../kubernetes/modules/prometheus"
  # ...
  server_resources = {
    requests = {
      cpu    = "1000m"
      memory = "2Gi"
    }
    limits = {
      cpu    = "2000m"
      memory = "4Gi"
    }
  }
  storage_size = "100Gi"
}
```

---

## Notes

* You can customize each module independently.
* To reduce cost in your demo environment, you can tweak VM sizes and database tiers in `main.tf`.
* Don't forget to destroy resources when finished:

```bash
terraform destroy
```
