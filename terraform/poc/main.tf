terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.25.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# --- VPC ---

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
}

# --- Subnet Groups (shared private subnets for all data services) ---

resource "aws_db_subnet_group" "platform" {
  name       = "${var.project}-db-subnets"
  subnet_ids = module.vpc.private_subnets

  tags = { Name = "${var.project}-db-subnets" }
}

resource "aws_elasticache_subnet_group" "platform" {
  name       = "${var.project}-cache-subnets"
  subnet_ids = module.vpc.private_subnets

  tags = { Name = "${var.project}-cache-subnets" }
}

# --- EKS Auto Mode ---

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.project}-cluster"
  kubernetes_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  endpoint_public_access = true
}

# --- EKS Capabilities ---

resource "aws_iam_role" "capability_kro" {
  name = "${var.project}-capability-kro"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "capabilities.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role" "capability_argocd" {
  name = "${var.project}-capability-argocd"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "capabilities.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_eks_capability" "kro" {
  cluster_name              = module.eks.cluster_name
  capability_name           = "platform-kro"
  type                      = "KRO"
  role_arn                  = aws_iam_role.capability_kro.arn
  delete_propagation_policy = "RETAIN"

  depends_on = [aws_iam_role.capability_kro]
}

resource "aws_eks_capability" "ack" {
  cluster_name              = module.eks.cluster_name
  capability_name           = "platform-ack"
  type                      = "ACK"
  role_arn                  = aws_iam_role.ack.arn
  delete_propagation_policy = "RETAIN"

  depends_on = [aws_iam_role.ack]
}

resource "aws_eks_capability" "argocd" {
  cluster_name              = module.eks.cluster_name
  capability_name           = "platform-argocd"
  type                      = "ARGOCD"
  role_arn                  = aws_iam_role.capability_argocd.arn
  delete_propagation_policy = "RETAIN"

  configuration {
    argo_cd {
      namespace = "argocd"
      aws_idc {
        idc_instance_arn = "arn:aws:sso:::instance/ssoins-7223e7008810806e"
      }
      rbac_role_mapping {
        role = "ADMIN"
        identity {
          id   = "90670f75ee-3106e43d-8ad8-468b-8297-ce439a96bb55"
          type = "SSO_USER"
        }
      }
    }
  }

  depends_on = [aws_iam_role.capability_argocd]
}

# --- ECR Repositories ---

resource "aws_ecr_repository" "charts" {
  for_each = toset([
    "team-database",
    "team-cache",
    "team-pubsub",
    "application-rgd",
  ])

  name                 = "${var.project}/charts/${each.value}"
  image_tag_mutability = "IMMUTABLE"
}

# --- IAM Role for ACK Capability ---

resource "aws_iam_role" "ack" {
  name = "${var.project}-ack-capability"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "capabilities.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ack_rds" {
  role       = aws_iam_role.ack.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

resource "aws_iam_role_policy_attachment" "ack_elasticache" {
  role       = aws_iam_role.ack.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess"
}

resource "aws_iam_role_policy_attachment" "ack_sns" {
  role       = aws_iam_role.ack.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
}

resource "aws_iam_role_policy_attachment" "ack_sqs" {
  role       = aws_iam_role.ack.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

resource "aws_iam_role_policy_attachment" "ack_iam" {
  role       = aws_iam_role.ack.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

resource "aws_iam_role_policy_attachment" "ack_secretsmanager" {
  role       = aws_iam_role.ack.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}
