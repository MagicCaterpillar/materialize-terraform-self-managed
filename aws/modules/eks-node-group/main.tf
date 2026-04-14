locals {
  node_labels = merge(
    var.labels,
    var.swap_enabled ? {
      "materialize.cloud/swap"                 = "true"
      "materialize.cloud/disk-config-required" = "true"
    } : {}
  )

  swap_bootstrap_args = <<-EOF
    [settings.bootstrap-containers.diskstrap]
    source = "${var.disk_setup_image}"
    mode = "always"
    essential = true
    user-data = "${base64encode(jsonencode(["swap", "--cloud-provider", "aws", "--bottlerocket-enable-swap"]))}"

    [settings.kernel.sysctl]
    "vm.swappiness" = "100"
    "vm.min_free_kbytes" = "1048576"
    "vm.watermark_scale_factor" = "100"
  EOF
}

# Clean up orphaned ENIs associated with this node group's security group.
#
# When the node group is destroyed, the VPC CNI plugin on terminating nodes
# may not clean up ENIs it created. These ENIs remain associated with the
# node security group, preventing Terraform from deleting it.
#
# The node group depends_on this resource, so during destroy the node group
# is deleted first, then this cleanup runs, then the security group (in the
# parent EKS module) can be deleted cleanly.
#
# Only ENIs in "available" status (not attached to any instance) are cleaned
# up, so ENIs belonging to still-running nodes from other node groups are
# left untouched.
resource "terraform_data" "eni_cleanup" {
  triggers_replace = {
    security_group_id = var.cluster_primary_security_group_id
    cluster_name      = var.cluster_name
    node_group_name   = var.node_group_name
    region            = var.aws_region
    profile           = var.aws_profile
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = <<-SCRIPT
      set -euo pipefail

      SG_ID="${self.triggers_replace.security_group_id}"
      REGION="${self.triggers_replace.region}"
      PROFILE="${self.triggers_replace.profile}"

      PROFILE_ARGS=""
      if [ -n "$PROFILE" ]; then
        PROFILE_ARGS="--profile $PROFILE"
      fi

      echo "Cleaning up orphaned ENIs for security group $SG_ID in $REGION..."

      CLUSTER_NAME="${self.triggers_replace.cluster_name}"
      NODE_GROUP_PREFIX="${self.triggers_replace.node_group_name}"

      delete_eni() {
        local ENI_ID="$1"
        echo "  Deleting $ENI_ID..."
        # The ENI may have been deleted between the list call and now
        # (e.g. by the VPC CNI). Treat NotFound as success.
        DELETE_OUTPUT=$(aws ec2 delete-network-interface \
          --network-interface-id "$ENI_ID" \
          --region "$REGION" $PROFILE_ARGS 2>&1) || {
          if echo "$DELETE_OUTPUT" | grep -q "InvalidNetworkInterfaceID.NotFound"; then
            echo "  Already deleted, skipping."
            return 0
          fi
          echo "$DELETE_OUTPUT" >&2
          return 1
        }
      }

      # ENIs come in two tag styles:
      # 1. EKS-managed: eks:cluster-name + eks:nodegroup-name
      # 2. VPC CNI-managed: cluster.k8s.amazonaws.com/name
      echo "Cleaning up EKS-tagged ENIs..."
      EKS_ENIS=$(aws ec2 describe-network-interfaces \
        --filters \
          "Name=group-id,Values=$SG_ID" \
          "Name=status,Values=available" \
          "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
        --query "NetworkInterfaces[?TagSet[?Key=='eks:nodegroup-name' && starts_with(Value, '$NODE_GROUP_PREFIX')]].NetworkInterfaceId" \
        --output text \
        --region "$REGION" $PROFILE_ARGS)

      for ENI_ID in $EKS_ENIS; do
        [ "$ENI_ID" = "None" ] && continue
        delete_eni "$ENI_ID"
      done

      echo "Cleaning up VPC CNI-tagged ENIs..."
      CNI_ENIS=$(aws ec2 describe-network-interfaces \
        --filters \
          "Name=group-id,Values=$SG_ID" \
          "Name=status,Values=available" \
          "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER_NAME" \
        --query "NetworkInterfaces[*].NetworkInterfaceId" \
        --output text \
        --region "$REGION" $PROFILE_ARGS)

      for ENI_ID in $CNI_ENIS; do
        [ "$ENI_ID" = "None" ] && continue
        delete_eni "$ENI_ID"
      done

      echo "ENI cleanup complete."
    SCRIPT
  }
}

module "node_group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 20.0"

  cluster_name   = var.cluster_name
  subnet_ids     = var.subnet_ids
  name           = var.node_group_name
  desired_size   = var.desired_size
  min_size       = var.min_size
  max_size       = var.max_size
  instance_types = var.instance_types
  capacity_type  = var.capacity_type
  ami_type       = var.ami_type
  labels         = local.node_labels

  taints = var.node_taints

  # useful to disable this when prefix might be too long and hit following char limit
  # expected length of name_prefix to be in the range (1 - 38)
  iam_role_use_name_prefix = var.iam_role_use_name_prefix

  iam_role_permissions_boundary = var.iam_permissions_boundary

  launch_template_name = var.launch_template_name

  bootstrap_extra_args = var.swap_enabled ? local.swap_bootstrap_args : ""

  cluster_service_cidr              = var.cluster_service_cidr
  cluster_primary_security_group_id = var.cluster_primary_security_group_id

  tags = var.tags

  depends_on = [terraform_data.eni_cleanup]
}
