"""OpenClawInstance CRD operations"""
from app.config import Config
from datetime import datetime
import logging
import copy

logger = logging.getLogger(__name__)

def create_openclaw_instance(k8s_client, user_id, namespace, user_email, cognito_sub=None, custom_config=None):
    """
    Create an OpenClawInstance CRD

    Args:
        k8s_client: K8sClient instance
        user_id: User ID
        namespace: Namespace name
        user_email: User email address
        cognito_sub: Cognito Sub ID (optional)
        custom_config: Custom configuration to override defaults (optional)

    Returns:
        Tuple of (instance, created)
    """
    instance_name = f"openclaw-{user_id}"

    # Merge configuration (custom_config overrides defaults)
    config = copy.deepcopy(Config.OPENCLAW_DEFAULTS)
    if custom_config:
        _deep_merge(config, custom_config)

    # Build OpenClawInstance CRD
    instance_body = {
        "apiVersion": "openclaw.rocks/v1alpha1",
        "kind": "OpenClawInstance",
        "metadata": {
            "name": instance_name,
            "namespace": namespace,
            "labels": {
                "openclaw.rocks/user-id": user_id,
                "openclaw.rocks/user-email": user_email,
                "app.kubernetes.io/managed-by": "openclaw-provisioning-service"
            },
            "annotations": {
                "openclaw.rocks/created-at": datetime.utcnow().isoformat(),
                "openclaw.rocks/provisioning-method": "eks-pod-service",
                "openclaw.rocks/user-email": user_email
            }
        },
        "spec": {
            "config": {
                "raw": {
                    "agents": {
                        "defaults": {
                            "model": {
                                "primary": config['model']
                            }
                        }
                    }
                }
            },
            "envFrom": [
                {"secretRef": {"name": config['aws_credentials_secret']}}
            ],
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
                    "storageClass": config['storage_class']
                }
            },
            "networking": {
                "service": {
                    "type": "ClusterIP"
                }
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
                "rbac": {
                    "createServiceAccount": True
                }
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
