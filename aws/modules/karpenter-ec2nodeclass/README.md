## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.8 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_deepmerge"></a> [deepmerge](#requirement\_deepmerge) | ~> 1.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | 2.4.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | 2.4.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [kubectl_manifest.ec2nodeclass](https://registry.terraform.io/providers/alekc/kubectl/2.4.0/docs/resources/manifest) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ami_selector_terms"></a> [ami\_selector\_terms](#input\_ami\_selector\_terms) | Terms for selecting which AMI to launch. See https://karpenter.sh/docs/tasks/managing-amis/ for more information. Only Bottlerocket AMIs are supported by this terraform code. | `list(any)` | n/a | yes |
| <a name="input_disk_setup_image"></a> [disk\_setup\_image](#input\_disk\_setup\_image) | Docker image for disk bootstraping when swap is enabled. | `string` | `"docker.io/materialize/ephemeral-storage-setup-image:v0.4.1"` | no |
| <a name="input_instance_profile"></a> [instance\_profile](#input\_instance\_profile) | Name of the instance profile to assign to nodes. | `string` | n/a | yes |
| <a name="input_instance_types"></a> [instance\_types](#input\_instance\_types) | List of instance types to support. | `list(string)` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Name of the EC2NodeClass. | `string` | n/a | yes |
| <a name="input_prefix_delegation_enabled"></a> [prefix\_delegation\_enabled](#input\_prefix\_delegation\_enabled) | Whether the CNI is configured to assign CIDR block prefixes instead of single IP addresses. | `bool` | `false` | no |
| <a name="input_security_group_ids"></a> [security\_group\_ids](#input\_security\_group\_ids) | List of security group IDs to assign to nodes. | `list(string)` | n/a | yes |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | List of subnet IDs to launch nodes into. | `list(string)` | n/a | yes |
| <a name="input_swap_enabled"></a> [swap\_enabled](#input\_swap\_enabled) | Whether to enable swap on the local NVMe disks. | `bool` | `true` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to AWS resources created. | `map(string)` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_kube_reserved_cpus_description"></a> [kube\_reserved\_cpus\_description](#output\_kube\_reserved\_cpus\_description) | Quantity of CPUs to reserve for the kubelet. |
| <a name="output_kube_reserved_memory_description"></a> [kube\_reserved\_memory\_description](#output\_kube\_reserved\_memory\_description) | Quantity of memory to reserve for the kubelet. |
