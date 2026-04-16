################################################################################
# Variables for OpenClaw Provisioning Service Module
#
# Workshop-only demo tool for batch creating/managing OpenClaw instances.
################################################################################

# --- Required ---

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_oidc_issuer" {
  description = "OIDC issuer URL for the EKS cluster (for IRSA)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  type        = string
}

variable "bedrock_role_arn" {
  description = "ARN of the Bedrock IAM role that OpenClaw user instances assume"
  type        = string
}

# --- Optional ---

variable "namespace" {
  description = "Kubernetes namespace for the provisioning service and PostgreSQL"
  type        = string
  default     = "openclaw-provisioning"
}

variable "openclaw_namespace" {
  description = "Kubernetes namespace where OpenClaw user instances are created"
  type        = string
  default     = "openclaw"
}

variable "provisioning_image" {
  description = "Docker image for the provisioning service"
  type        = string
  default     = "public.ecr.aws/i6v0m5n6/openclaw-provisioning-chinaregion:latest"
}

variable "openclaw_version" {
  description = "OpenClaw image tag for provisioned user instances"
  type        = string
  default     = "2026.3.1"
}

variable "openclaw_image_repository" {
  description = "Override OpenClaw image repository (for China regions). Empty = default ghcr.io."
  type        = string
  default     = ""
}

variable "postgres_storage_size" {
  description = "PVC storage size for PostgreSQL"
  type        = string
  default     = "10Gi"
}

variable "postgres_storage_class" {
  description = "StorageClass name for PostgreSQL PVC"
  type        = string
  default     = "ebs-sc"
}

variable "replicas" {
  description = "Number of provisioning service replicas"
  type        = number
  default     = 1
}

variable "is_china_region" {
  description = "Whether the deployment targets an AWS China region"
  type        = bool
  default     = false
}

variable "partition" {
  description = "AWS partition (aws or aws-cn)"
  type        = string
  default     = "aws"
}

variable "tags" {
  description = "Tags to apply to all AWS resources created by this module"
  type        = map(string)
  default     = {}
}
