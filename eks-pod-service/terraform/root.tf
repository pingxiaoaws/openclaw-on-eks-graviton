################################################################################
# Provisioning Service — Standalone Terraform Root
#
# Deploys the OpenClaw Provisioning Service (Web UI + batch tools)
# on an existing EKS cluster deployed by the main Terraform project.
#
# Usage:
#   terraform init -backend-config="bucket=<TF_STATE_BUCKET>" \
#                  -backend-config="region=<REGION>"
#   terraform apply -var="cluster_name=openclaw-workshop" \
#                   -var="region=us-west-2"
################################################################################

terraform {
  backend "s3" {
    key = "openclaw/provisioning.tfstate"
    # bucket and region provided via -backend-config
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

data "aws_iam_role" "bedrock" {
  name = "${var.cluster_name}-openclaw-bedrock"
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

locals {
  region      = var.region
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  is_china    = startswith(var.region, "cn-")
  oidc_issuer = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  # Find OIDC provider ARN from the cluster's OIDC issuer
  oidc_provider_arn = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.oidc_issuer}"
}

module "provisioning" {
  source = "./modules/provisioning"

  cluster_name        = var.cluster_name
  cluster_oidc_issuer = local.oidc_issuer
  oidc_provider_arn   = local.oidc_provider_arn
  bedrock_role_arn    = data.aws_iam_role.bedrock.arn

  openclaw_version         = var.openclaw_version
  provisioning_image       = var.provisioning_image
  openclaw_image_repository = var.openclaw_image_repository
  postgres_storage_class   = "ebs-sc"

  is_china_region = local.is_china
  partition       = local.partition

  tags = {
    ManagedBy = "terraform"
    Component = "provisioning-service"
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "openclaw-workshop"
}

variable "openclaw_version" {
  description = "OpenClaw version for user instances"
  type        = string
  default     = "2026.4.14"
}

variable "provisioning_image" {
  description = "Provisioning Service Docker image"
  type        = string
  default     = "public.ecr.aws/i6v0m5n6/openclaw-provisioning-chinaregion:latest"
}

variable "openclaw_image_repository" {
  description = "OpenClaw image repository for user instances"
  type        = string
  default     = "ghcr.io/openclaw/openclaw"
}

################################################################################
# Outputs
################################################################################

output "provisioning_url" {
  description = "Internet-facing URL of the provisioning service"
  value       = module.provisioning.url
}

# Write to SSM so CodeBuild post_build can surface it
resource "aws_ssm_parameter" "provisioning_url" {
  name  = "/${var.cluster_name}/provisioning-url"
  type  = "String"
  value = module.provisioning.url
  overwrite = true
}
