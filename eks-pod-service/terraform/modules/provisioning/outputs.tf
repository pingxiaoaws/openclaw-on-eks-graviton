################################################################################
# Outputs for OpenClaw Provisioning Service Module
################################################################################

output "namespace" {
  description = "Kubernetes namespace where the provisioning service is deployed"
  value       = kubernetes_namespace_v1.provisioning.metadata[0].name
}

output "service_name" {
  description = "Name of the provisioning service Kubernetes Service"
  value       = kubernetes_service_v1.provisioning.metadata[0].name
}

output "service_port" {
  description = "Port of the provisioning service Kubernetes Service"
  value       = 80
}

output "iam_role_arn" {
  description = "ARN of the IAM role used by the provisioning service"
  value       = aws_iam_role.provisioning.arn
}

output "postgres_service" {
  description = "PostgreSQL service endpoint (hostname:port) within the cluster"
  value       = "${kubernetes_service_v1.postgres.metadata[0].name}.${var.namespace}.svc.cluster.local:5432"
}
