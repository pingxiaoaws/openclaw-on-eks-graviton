################################################################################
# OpenClaw Provisioning Service Module
#
# Deploys the Provisioning Service — a workshop-only demo tool that provides
# a Web UI for batch creating and managing OpenClaw instances on EKS.
#
# Components:
#   - Namespace
#   - PostgreSQL (StatefulSet + PVC + Service + Secret)
#   - Provisioning Service (Deployment + Service + Secret)
#   - RBAC (ServiceAccount + ClusterRole + ClusterRoleBinding)
#   - IAM Role for Provisioning Service (Pod Identity / IRSA)
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# =============================================================================
# Namespace
# =============================================================================

resource "kubernetes_namespace_v1" "provisioning" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "openclaw-provisioning"
    }
  }
}

# =============================================================================
# PostgreSQL
# =============================================================================

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres-secret"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
  }

  data = {
    POSTGRES_USER     = "openclaw"
    POSTGRES_PASSWORD = "OpenClaw2026!SecureDB"
    POSTGRES_DB       = "openclaw"
  }
}

resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
    labels = {
      app = "postgres"
    }
  }

  spec {
    type = "ClusterIP"
    selector = {
      app = "postgres"
    }
    port {
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
      name        = "postgres"
    }
  }
}

resource "kubernetes_stateful_set_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
    labels = {
      app = "postgres"
    }
  }

  spec {
    service_name = "postgres"
    replicas     = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        container {
          name              = "postgres"
          image             = "postgres:15-alpine"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 5432
            name           = "postgres"
          }

          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "openclaw"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "openclaw"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "postgres-data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.postgres_storage_class
        resources {
          requests = {
            storage = var.postgres_storage_size
          }
        }
      }
    }
  }
}

# =============================================================================
# RBAC — ServiceAccount, ClusterRole, ClusterRoleBinding
# =============================================================================

resource "kubernetes_service_account_v1" "provisioner" {
  metadata {
    name      = "openclaw-provisioner"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.provisioning.arn
    }
  }
}

resource "kubernetes_cluster_role_v1" "provisioner" {
  metadata {
    name = "openclaw-provisioner"
  }

  # Namespace management
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["create", "get", "list", "delete"]
  }

  # User namespace resources
  rule {
    api_groups = [""]
    resources  = ["resourcequotas", "services"]
    verbs      = ["create", "get", "list"]
  }

  # NetworkPolicy
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = ["create", "get", "list"]
  }

  # Ingress (for instance ingress management)
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["create", "get", "list", "update", "patch"]
  }

  # OpenClawInstance CRD
  rule {
    api_groups = ["openclaw.rocks"]
    resources  = ["openclawinstances"]
    verbs      = ["create", "get", "list", "watch", "delete"]
  }

  # Pod status + exec (for device pairing)
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create", "get"]
  }

  # Endpoints (readiness checking)
  rule {
    api_groups = [""]
    resources  = ["endpoints"]
    verbs      = ["get", "list"]
  }

  # Secrets (gateway token retrieval)
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list"]
  }

  # StatefulSet status checking
  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "provisioner" {
  metadata {
    name = "openclaw-provisioner"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.provisioner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.provisioner.metadata[0].name
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
  }
}

# =============================================================================
# IAM — Provisioning Service Role (manages user IAM roles + Pod Identity)
# =============================================================================

resource "aws_iam_policy" "provisioning" {
  name        = "${var.cluster_name}-provisioning-service"
  description = "Allow OpenClaw provisioning service to manage user IAM roles and Pod Identity"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageUserIAMRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:TagRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies"
        ]
        Resource = "arn:${var.partition}:iam::${local.account_id}:role/openclaw-user-*"
      },
      {
        Sid    = "PassRoleToServiceAccounts"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          var.bedrock_role_arn,
          "arn:${var.partition}:iam::${local.account_id}:role/openclaw-user-*"
        ]
      },
      {
        Sid      = "GetSharedBedrockRole"
        Effect   = "Allow"
        Action   = ["iam:GetRole"]
        Resource = var.bedrock_role_arn
      },
      {
        Sid    = "ManagePodIdentityAssociations"
        Effect = "Allow"
        Action = [
          "eks:CreatePodIdentityAssociation",
          "eks:DeletePodIdentityAssociation",
          "eks:DescribePodIdentityAssociation",
          "eks:ListPodIdentityAssociations"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role" "provisioning" {
  name        = "${var.cluster_name}-provisioning-service"
  description = "IAM role for OpenClaw provisioning service via IRSA"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(var.cluster_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:${var.namespace}:openclaw-provisioner"
            "${replace(var.cluster_oidc_issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "provisioning" {
  role       = aws_iam_role.provisioning.name
  policy_arn = aws_iam_policy.provisioning.arn
}

# =============================================================================
# Provisioning Service Secret (Flask secret key)
# =============================================================================

resource "random_password" "flask_secret" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "provisioning" {
  metadata {
    name      = "openclaw-provisioning-secret"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
  }

  data = {
    "secret-key" = random_password.flask_secret.result
  }
}

# =============================================================================
# Provisioning Service Deployment
# =============================================================================

resource "kubernetes_deployment_v1" "provisioning" {
  metadata {
    name      = "openclaw-provisioning"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
    labels = {
      app = "openclaw-provisioning"
    }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        app = "openclaw-provisioning"
      }
    }

    template {
      metadata {
        labels = {
          app = "openclaw-provisioning"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.provisioner.metadata[0].name

        container {
          name              = "provisioning"
          image             = var.provisioning_image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "LOG_LEVEL"
            value = "INFO"
          }
          env {
            name  = "USE_POD_IDENTITY"
            value = "true"
          }
          env {
            name  = "SHARED_BEDROCK_ROLE_ARN"
            value = var.bedrock_role_arn
          }
          env {
            name  = "EKS_CLUSTER_NAME"
            value = var.cluster_name
          }
          env {
            name  = "AWS_REGION"
            value = local.region
          }
          env {
            name  = "AWS_ACCOUNT_ID"
            value = local.account_id
          }
          env {
            name  = "OPENCLAW_IMAGE_REPOSITORY"
            value = var.openclaw_image_repository
          }
          env {
            name  = "OPENCLAW_IMAGE_TAG"
            value = var.openclaw_version
          }

          # PostgreSQL
          env {
            name  = "POSTGRES_HOST"
            value = "postgres"
          }
          env {
            name  = "POSTGRES_PORT"
            value = "5432"
          }
          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = "POSTGRES_DB"
              }
            }
          }
          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = "POSTGRES_USER"
              }
            }
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_stateful_set_v1.postgres,
    kubernetes_cluster_role_binding_v1.provisioner,
  ]
}

# =============================================================================
# Provisioning Service — ClusterIP Service
# =============================================================================

resource "kubernetes_service_v1" "provisioning" {
  metadata {
    name      = "openclaw-provisioning"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
    labels = {
      app = "openclaw-provisioning"
    }
  }

  spec {
    type = "ClusterIP"
    selector = {
      app = "openclaw-provisioning"
    }
    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
      name        = "http"
    }
  }
}

# =============================================================================
# HPA (optional, for workshop scale)
# =============================================================================

resource "kubernetes_horizontal_pod_autoscaler_v2" "provisioning" {
  metadata {
    name      = "openclaw-provisioning"
    namespace = kubernetes_namespace_v1.provisioning.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.provisioning.metadata[0].name
    }

    min_replicas = var.replicas
    max_replicas = max(var.replicas * 2, 3)

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }

    behavior {
      scale_down {
        stabilization_window_seconds = 300
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 60
        }
      }
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 30
        }
        policy {
          type           = "Pods"
          value          = 2
          period_seconds = 30
        }
      }
    }
  }
}
