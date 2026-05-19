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
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [kubectl_manifest.nodepool](https://registry.terraform.io/providers/alekc/kubectl/2.4.0/docs/resources/manifest) | resource |
| [terraform_data.destroyer](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_disruption"></a> [disruption](#input\_disruption) | Configuration for node disruption. | `any` | <pre>{<br/>  "budgets": [<br/>    {<br/>      "nodes": "10%"<br/>    }<br/>  ],<br/>  "consolidateAfter": "60s",<br/>  "consolidationPolicy": "WhenEmpty"<br/>}</pre> | no |
| <a name="input_expire_after"></a> [expire\_after](#input\_expire\_after) | Time after which the node will expire. | `string` | `"Never"` | no |
| <a name="input_instance_types"></a> [instance\_types](#input\_instance\_types) | List of instance types to support. | `list(string)` | n/a | yes |
| <a name="input_kubeconfig_data"></a> [kubeconfig\_data](#input\_kubeconfig\_data) | Contents of the kubeconfig used for cleanup of EC2 instances on destroy. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Name of the NodePool. | `string` | n/a | yes |
| <a name="input_node_labels"></a> [node\_labels](#input\_node\_labels) | Labels to apply to created Kubernetes nodes. | `map(string)` | n/a | yes |
| <a name="input_node_taints"></a> [node\_taints](#input\_node\_taints) | Taints to apply to the node. | <pre>list(object({<br/>    key    = string<br/>    value  = string<br/>    effect = string<br/>  }))</pre> | `null` | no |
| <a name="input_nodeclass_name"></a> [nodeclass\_name](#input\_nodeclass\_name) | Name of the EC2NodeClass. | `string` | n/a | yes |

## Outputs

No outputs.
