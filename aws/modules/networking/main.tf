
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  create_vpc = var.create_vpc

  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Adopt the AWS-default network ACL and apply our tags so that the BYOC
  # permissions boundary's ResourceTag-gated allow for `ec2:Delete*` (and
  # `ec2:*NetworkAclEntry`) matches at destroy time.  Upstream defaults
  # `manage_default_network_acl` to false, which leaves the ACL untagged
  # and destroy calls fail with UnauthorizedOperation.
  manage_default_network_acl = true

  # needed for EKS Cluster private endpoint
  # https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html#cluster-endpoint-private
  enable_dhcp_options              = true
  dhcp_options_domain_name_servers = ["AmazonProvidedDNS"]

  # Tags required for EKS
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${var.name_prefix}-eks" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${var.name_prefix}-eks" = "shared"
  }

  tags = var.tags

}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  create = var.enable_vpc_endpoints

  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = var.enable_vpc_endpoints ? [aws_security_group.vpc_endpoints[0].id] : []

  endpoints = {
    # we store metadata in s3 all pod requests go through this endpoint
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${var.name_prefix}-s3-gateway-endpoint" }
    }

    # not adding aws rds endpoint as it will add up unnecessary cost
    # pods connect to rds using private ip. The traffic doesn't leave vpc so not needed.
    # we would endup paying extra $0.02*24*30 = $14.4 per month even if we don't use it.
    # https://aws.amazon.com/privatelink/pricing/

    # ec2 api is useful for Karpenter
    ec2 = {
      service             = "ec2"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-ec2-endpoint" }
    }

    # not needed secretsmanager endpoint as we use k8s secrets, discuss and remove it.
    secretsmanager = {
      service             = "secretsmanager"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-secretsmanager-endpoint" }
    }

    # Required for AWS Session Manager to work, useful to ssh into worker nodes via aws console/cli
    ssm = {
      service             = "ssm"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-ssm-endpoint" }
    }
    ssmmessages = {
      service             = "ssmmessages"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-ssmmessages-endpoint" }
    }
    ec2messages = {
      service             = "ec2messages"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-ec2messages-endpoint" }
    }

    # sts endpoint is useful for IRSA
    sts = {
      service             = "sts"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-sts-endpoint" }
    }

    # not needed kms endpoint as we rely on ebs encryption in nodes, discuss and remove it.
    kms = {
      service             = "kms"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-kms-endpoint" }
    }

    # Allows private access to the ELB API to create/manage load balancers. Useful for aws-lbc
    elasticloadbalancing = {
      service             = "elasticloadbalancing"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-elasticloadbalancing-endpoint" }
    }

    # for image pulls from ecr
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-ecr-api-endpoint" }
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      tags                = { Name = "${var.name_prefix}-ecr-dkr-endpoint" }
    }
  }

  tags = var.tags
}

resource "aws_security_group" "vpc_endpoints" {
  count       = var.enable_vpc_endpoints ? 1 : 0
  name        = "${var.name_prefix}-vpc-endpoints"
  description = "Security group for VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = var.tags
}
