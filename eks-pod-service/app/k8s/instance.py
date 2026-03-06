"""OpenClawInstance CRD operations"""
from app.config import Config
from datetime import datetime
import logging
import copy

logger = logging.getLogger(__name__)

def create_openclaw_instance(k8s_client, user_id, namespace, user_email, cognito_sub=None, custom_config=None, role_arn=None, provider='bedrock', siliconflow_api_key=None):
    """
    Create an OpenClawInstance CRD

    Args:
        k8s_client: K8sClient instance
        user_id: User ID
        namespace: Namespace name
        user_email: User email address
        cognito_sub: Cognito Sub ID (optional)
        custom_config: Custom configuration to override defaults (optional)
        role_arn: IAM Role ARN for Pod Identity (optional)
        provider: LLM provider - 'bedrock' or 'siliconflow' (default: 'bedrock')
        siliconflow_api_key: SiliconFlow API key (required when provider='siliconflow')

    Returns:
        Tuple of (instance, created)
    """
    instance_name = f"openclaw-{user_id}"

    # Merge configuration (custom_config overrides defaults)
    config = copy.deepcopy(Config.OPENCLAW_DEFAULTS)
    if custom_config:
        _deep_merge(config, custom_config)

    # Build config.raw based on provider
    if provider == 'siliconflow':
        sf = Config.SILICONFLOW_DEFAULTS
        config_raw = {
            "gateway": {
                "controlUi": {
                    "allowedOrigins": Config.GATEWAY_CONFIG["allowedOrigins"]
                },
                "trustedProxies": Config.GATEWAY_CONFIG["trustedProxies"]
            },
            "models": {
                "providers": {
                    "siliconflow": {
                        "baseUrl": sf['base_url'],
                        "api": "openai-completions",
                        "auth": "api-key",
                        "apiKey": siliconflow_api_key,
                        "models": [{
                            "id": sf['model'],
                            "name": "SiliconFlow Model",
                            "input": ["text"],
                            "contextWindow": sf['context_window'],
                            "maxTokens": sf['max_tokens']
                        }]
                    }
                }
            },
            "agents": {
                "defaults": {
                    "model": {
                        "primary": f"siliconflow/{sf['model']}"
                    }
                }
            }
        }
    else:  # bedrock (default)
        config_raw = {
            "gateway": {
                "controlUi": {
                    "allowedOrigins": Config.GATEWAY_CONFIG["allowedOrigins"]
                },
                "trustedProxies": Config.GATEWAY_CONFIG["trustedProxies"]
            },
            "agents": {
                "defaults": {
                    "model": {
                        "primary": config['model']
                    }
                }
            }
        }

    # Build labels
    labels = {
        "openclaw.rocks/user-id": user_id,
        "app.kubernetes.io/managed-by": "openclaw-provisioning-service",
        "openclaw.rocks/llm-provider": provider
    }

    # Build RBAC section
    rbac_config = {
        "createServiceAccount": True,
    }
    if role_arn:
        rbac_config["serviceAccountAnnotations"] = {
            "eks.amazonaws.com/role-arn": role_arn
        }

    # Build OpenClawInstance CRD
    instance_body = {
        "apiVersion": "openclaw.rocks/v1alpha1",
        "kind": "OpenClawInstance",
        "metadata": {
            "name": instance_name,
            "namespace": namespace,
            "labels": labels,
            "annotations": {
                "openclaw.rocks/created-at": datetime.utcnow().isoformat(),
                "openclaw.rocks/provisioning-method": "eks-pod-service",
                "openclaw.rocks/user-email": user_email
            }
        },
        "spec": {
            "config": {
                "raw": config_raw
            },
            "resources": config['resources'],
            "availability": {
                "runtimeClassName": config['runtime_class'],
                "nodeSelector": config['node_selector'],
                "tolerations": config['tolerations']
            },
            "storage": {
                "persistence": {
                    "enabled": True,
                    "size": config['storage_size'],
                    "storageClass": config['storage_class'],
                    "accessModes": ["ReadWriteOnce"] if config['storage_class'] == 'gp3' else ["ReadWriteMany"]
                }
            },
            "networking": {
                "service": {
                    "type": "ClusterIP"
                },
                "ingress": _build_ingress_config(user_id) if Config.INGRESS_ENABLED else {"enabled": False}
            },
            "security": {
                "podSecurityContext": {
                    "runAsUser": 1000,
                    "runAsGroup": 1000,
                    "fsGroup": 1000,
                    "runAsNonRoot": True
                },
                "containerSecurityContext": {
                    "allowPrivilegeEscalation": False,
                    "readOnlyRootFilesystem": False,
                    "capabilities": {"drop": ["ALL"]}
                },
                "networkPolicy": {
                    "enabled": True,
                    "allowDNS": True
                },
                "rbac": rbac_config
            },
            "observability": {
                "metrics": {
                    "enabled": True,
                    "port": 9090
                },
                "logging": {
                    "level": "info",
                    "format": "json"
                }
            }
        }
    }

    # Add cognito_sub if provided
    if cognito_sub:
        instance_body["metadata"]["labels"]["openclaw.rocks/cognito-sub"] = cognito_sub

    def create():
        return k8s_client.custom_objects.create_namespaced_custom_object(
            group="openclaw.rocks",
            version="v1alpha1",
            namespace=namespace,
            plural="openclawinstances",
            body=instance_body
        )

    def get():
        return k8s_client.custom_objects.get_namespaced_custom_object(
            group="openclaw.rocks",
            version="v1alpha1",
            namespace=namespace,
            plural="openclawinstances",
            name=instance_name
        )

    return k8s_client.create_or_get(create, get, f"OpenClawInstance {instance_name}")


def _build_ingress_config(user_id):
    """
    Build Ingress configuration for Public ALB behind CloudFront (NEW) or Internal ALB via API Gateway (OLD)

    Architecture (Public ALB + CloudFront - RECOMMENDED):
      User → CloudFront (HTTPS) → Internet-Facing ALB → OpenClaw

    Architecture (Internal ALB + API Gateway - OLD):
      User → API Gateway (JWT auth) → VPC Link → Internal ALB → OpenClaw

    Args:
        user_id: User ID for generating unique path

    Returns:
        Dict: Ingress configuration
    """
    if Config.USE_PUBLIC_ALB:
        # Public ALB + CloudFront 模式
        config = {
            "enabled": True,
            "className": Config.INGRESS_CLASS,
            "annotations": {
                # Merge Public ALB annotations
                **Config.PUBLIC_ALB_INGRESS_ANNOTATIONS,
                # Override healthcheck path
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/healthcheck-path": f"/instance/{user_id}/",
            },
            # Host-based routing with CloudFront domain
            "hosts": [{
                "host": Config.CLOUDFRONT_DOMAIN,
                "paths": [{
                    "path": f"/instance/{user_id}",
                    "pathType": "Prefix"
                }]
            }]
        }

        logger.info(f"✅ Public ALB Ingress configured for user {user_id} - path: /instance/{user_id}")
        logger.info(f"   Access via CloudFront: https://{Config.CLOUDFRONT_DOMAIN}/instance/{user_id}/")
        logger.info(f"   Direct ALB access: http://{Config.PUBLIC_ALB_DNS}/instance/{user_id}/")

    else:
        # Internal ALB + API Gateway 模式（原有逻辑）
        config = {
            "enabled": True,
            "className": Config.INGRESS_CLASS,
            "annotations": {
                # ALB Ingress Group - share single internal ALB across all instances
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/group.name": Config.INGRESS_GROUP_NAME,

                # Internal ALB - not exposed to internet
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/scheme": Config.INGRESS_SCHEME,

                # IP target mode for better performance
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/target-type": Config.INGRESS_TARGET_TYPE,

                # Health check
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/healthcheck-path": f"/instance/{user_id}/",
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/healthcheck-protocol": "HTTP",
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/success-codes": "200,404",  # 404 ok if gateway requires auth

                # Target Group Attributes - WebSocket optimization
                f"{Config.INGRESS_CLASS}.ingress.kubernetes.io/target-group-attributes": (
                    "stickiness.enabled=true,"
                    "stickiness.type=lb_cookie,"
                    "stickiness.lb_cookie.duration_seconds=3600,"
                    "deregistration_delay.timeout_seconds=60,"
                    "load_balancing.algorithm.type=least_outstanding_requests"
                ),
            },
            # Path-based routing only (no host - accessed via API Gateway)
            "hosts": [{
                "host": "",  # Empty host for path-based routing
                "paths": [{
                    "path": f"/instance/{user_id}",
                    "pathType": "Prefix"
                }]
            }]
        }

        logger.info(f"✅ Internal ALB Ingress configured for user {user_id} - path: /instance/{user_id}")
        logger.info(f"   Access via API Gateway: {Config.API_GATEWAY_ENDPOINT}/{Config.API_GATEWAY_STAGE}/instance/{user_id}/")

    return config


def _deep_merge(base, override):
    """
    Deep merge two dictionaries

    Args:
        base: Base dictionary (will be modified)
        override: Override dictionary
    """
    for key, value in override.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            _deep_merge(base[key], value)
        else:
            base[key] = value
