## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 2.5.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | 2.4.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.10.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | 2.4.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [kubectl_manifest.root_ca_cluster_issuer](https://registry.terraform.io/providers/alekc/kubectl/2.4.0/docs/resources/manifest) | resource |
| [kubectl_manifest.self_signed_cluster_issuer](https://registry.terraform.io/providers/alekc/kubectl/2.4.0/docs/resources/manifest) | resource |
| [kubectl_manifest.self_signed_root_ca_certificate](https://registry.terraform.io/providers/alekc/kubectl/2.4.0/docs/resources/manifest) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | The name prefix to use for Kubernetes resources. | `string` | n/a | yes |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | The namespace in which to create the root CA certificate object. | `string` | `"cert-manager"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_issuer_name"></a> [issuer\_name](#output\_issuer\_name) | Name of the ClusterIssuer |
