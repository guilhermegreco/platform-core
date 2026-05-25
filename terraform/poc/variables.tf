variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name (used as prefix for all resources)"
  type        = string
  default     = "plat-cp"
}

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.31"
}

variable "admin_role_arn" {
  description = "IAM role ARN for cluster admin access"
  type        = string
}
