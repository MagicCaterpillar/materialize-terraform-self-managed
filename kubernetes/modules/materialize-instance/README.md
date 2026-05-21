## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 2.2.0, < 2.3 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.10.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 2.2.0, < 2.3 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.10.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [kubectl_manifest.materialize_instance](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_config_map.system_params](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map) | resource |
| [kubernetes_namespace.instance](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_network_policy_v1.allow_api_server_egress](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/network_policy_v1) | resource |
| [kubernetes_network_policy_v1.allow_kube_system_egress](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/network_policy_v1) | resource |
| [kubernetes_network_policy_v1.allow_monitoring_ingress](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/network_policy_v1) | resource |
| [kubernetes_secret.materialize_backend](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_resource.materialize_instance](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/resource) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_authenticator_kind"></a> [authenticator\_kind](#input\_authenticator\_kind) | Kind of authenticator to use for Materialize instance | `string` | `"None"` | no |
| <a name="input_balancer_cpu_request"></a> [balancer\_cpu\_request](#input\_balancer\_cpu\_request) | CPU request for balancer | `string` | `"100m"` | no |
| <a name="input_balancer_memory_limit"></a> [balancer\_memory\_limit](#input\_balancer\_memory\_limit) | Memory limit for balancer | `string` | `"256Mi"` | no |
| <a name="input_balancer_memory_request"></a> [balancer\_memory\_request](#input\_balancer\_memory\_request) | Memory request for balancer | `string` | `"256Mi"` | no |
| <a name="input_balancerd_extra_dns_names"></a> [balancerd\_extra\_dns\_names](#input\_balancerd\_extra\_dns\_names) | Additional DNS names to include in the balancerd TLS certificate. Useful when balancerd is exposed via an external hostname. | `list(string)` | `[]` | no |
| <a name="input_console_extra_dns_names"></a> [console\_extra\_dns\_names](#input\_console\_extra\_dns\_names) | Additional DNS names to include in the console TLS certificate. Useful when the console is exposed via an external hostname (e.g., materialize.internal.example.com). | `list(string)` | `[]` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | CPU request for environmentd | `string` | `"1"` | no |
| <a name="input_crd_version"></a> [crd\_version](#input\_crd\_version) | CRD API version to use for the Materialize instance (v1alpha1 or v1alpha2). We recommend v1alpha2, but default to v1alpha1 for backwards compatibility. We will change this default in an upcoming major release. | `string` | `"v1alpha1"` | no |
| <a name="input_create_namespace"></a> [create\_namespace](#input\_create\_namespace) | Whether to create the Kubernetes namespace. Set to false if the namespace already exists. | `bool` | `true` | no |
| <a name="input_enable_network_policies"></a> [enable\_network\_policies](#input\_enable\_network\_policies) | Enable default-deny-ingress network policy for the instance namespace. Helm chart creates specific allow policies. | `bool` | `true` | no |
| <a name="input_environmentd_extra_args"></a> [environmentd\_extra\_args](#input\_environmentd\_extra\_args) | Extra command line arguments for environmentd | `list(string)` | `[]` | no |
| <a name="input_environmentd_extra_env"></a> [environmentd\_extra\_env](#input\_environmentd\_extra\_env) | Extra environment variables for environmentd | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_environmentd_version"></a> [environmentd\_version](#input\_environmentd\_version) | Version of environmentd to use | `string` | `"v26.24.2"` | no |
| <a name="input_external_login_password_mz_system"></a> [external\_login\_password\_mz\_system](#input\_external\_login\_password\_mz\_system) | Password for external login to mz\_system. Must be set if authenticator\_kind is 'Password', 'Sasl', or 'Oidc'. | `string` | `null` | no |
| <a name="input_force_rollout"></a> [force\_rollout](#input\_force\_rollout) | UUID to force a rollout | `string` | `"00000000-0000-0000-0000-000000000001"` | no |
| <a name="input_instance_name"></a> [instance\_name](#input\_instance\_name) | Name of the Materialize instance | `string` | n/a | yes |
| <a name="input_instance_namespace"></a> [instance\_namespace](#input\_instance\_namespace) | Kubernetes namespace for the instance. | `string` | n/a | yes |
| <a name="input_internal_issuer_ref"></a> [internal\_issuer\_ref](#input\_internal\_issuer\_ref) | Optional override for the issuer used to sign cluster-internal mTLS certs (those with *.cluster.local SANs). Required when var.issuer\_ref points at a public ACME issuer such as Let's Encrypt, since public CAs cannot sign cluster.local. When this is set, the short cluster service names ('balancerd', 'console') are also stripped from the external cert SANs because public ACME issuers reject single-label domains. When null, var.issuer\_ref is used for both internal and external certs. | <pre>object({<br/>    name = string<br/>    kind = string<br/>  })</pre> | `null` | no |
| <a name="input_issuer_ref"></a> [issuer\_ref](#input\_issuer\_ref) | Default cert-manager (Cluster)Issuer used for the instance's TLS certificates. Used for both the external (browser-facing) certs and the internal mTLS certs unless overridden by var.internal\_issuer\_ref. | <pre>object({<br/>    name = string<br/>    kind = string<br/>  })</pre> | `null` | no |
| <a name="input_license_key"></a> [license\_key](#input\_license\_key) | Materialize license key | `string` | `null` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | Memory limit for environmentd | `string` | `"4Gi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | Memory request for environmentd | `string` | `"4095Mi"` | no |
| <a name="input_metadata_backend_url"></a> [metadata\_backend\_url](#input\_metadata\_backend\_url) | PostgreSQL connection URL for metadata backend | `string` | n/a | yes |
| <a name="input_monitoring_namespace"></a> [monitoring\_namespace](#input\_monitoring\_namespace) | Namespace where monitoring resources (Prometheus) are installed. Used for network policy to allow metrics scraping. | `string` | `"monitoring"` | no |
| <a name="input_persist_backend_url"></a> [persist\_backend\_url](#input\_persist\_backend\_url) | S3 connection URL for persist backend | `string` | n/a | yes |
| <a name="input_pod_labels"></a> [pod\_labels](#input\_pod\_labels) | Labels for the materialize instance pod | `map(string)` | `{}` | no |
| <a name="input_request_rollout"></a> [request\_rollout](#input\_request\_rollout) | UUID to request a rollout (v1alpha1 only, ignored for v1alpha2) | `string` | `"00000000-0000-0000-0000-000000000001"` | no |
| <a name="input_rollout_strategy"></a> [rollout\_strategy](#input\_rollout\_strategy) | Strategy to use for rollouts | `string` | `"WaitUntilReady"` | no |
| <a name="input_service_account_annotations"></a> [service\_account\_annotations](#input\_service\_account\_annotations) | Annotations for the service account associated with the materialize instance. Useful for IAM roles assigned to the service account. | `map(string)` | `{}` | no |
| <a name="input_system_parameters"></a> [system\_parameters](#input\_system\_parameters) | System parameters to configure for the Materialize instance. These are passed via a ConfigMap. Common parameters include max\_connections, allowed\_cluster\_replica\_sizes, max\_clusters, max\_sources, max\_sinks. Set to null to skip creating the ConfigMap. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_instance_name"></a> [instance\_name](#output\_instance\_name) | Name of the Materialize instance |
| <a name="output_instance_namespace"></a> [instance\_namespace](#output\_instance\_namespace) | Namespace of the Materialize instance |
| <a name="output_instance_resource_id"></a> [instance\_resource\_id](#output\_instance\_resource\_id) | Resource ID of the Materialize instance |
| <a name="output_metadata_backend_url"></a> [metadata\_backend\_url](#output\_metadata\_backend\_url) | Metadata backend URL used by the Materialize instance |
| <a name="output_persist_backend_url"></a> [persist\_backend\_url](#output\_persist\_backend\_url) | Persist backend URL used by the Materialize instance |
