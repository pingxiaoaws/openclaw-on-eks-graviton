"""Ingress management for shared ALB"""
from kubernetes import client
from app.config import Config
import logging

logger = logging.getLogger(__name__)

def ensure_keeper_ingress():
    """
    Ensure keeper ingress exists to prevent shared ALB deletion

    This ingress is permanent and keeps the shared ALB alive even when
    all user instances are deleted. It's automatically created on service
    startup if it doesn't exist.

    The keeper ingress:
    - Uses the same group.name as user instances (shared ALB)
    - Lives in openclaw-provisioning namespace
    - Has a placeholder health check path
    """
    try:
        v1 = client.NetworkingV1Api()

        keeper_name = "openclaw-instances-keeper"
        keeper_namespace = "openclaw-provisioning"

        # Check if keeper ingress already exists
        try:
            v1.read_namespaced_ingress(
                name=keeper_name,
                namespace=keeper_namespace
            )
            logger.info(f"✅ Keeper ingress '{keeper_name}' already exists")
            return
        except client.exceptions.ApiException as e:
            if e.status != 404:
                raise
            # Not found, proceed to create

        # Create keeper ingress
        logger.info(f"📝 Creating keeper ingress '{keeper_name}'...")

        ingress = client.V1Ingress(
            api_version="networking.k8s.io/v1",
            kind="Ingress",
            metadata=client.V1ObjectMeta(
                name=keeper_name,
                namespace=keeper_namespace,
                annotations={
                    # Share the same ALB as OpenClaw instances
                    "alb.ingress.kubernetes.io/group.name": Config.INGRESS_GROUP_NAME,
                    "alb.ingress.kubernetes.io/scheme": Config.INGRESS_SCHEME,
                    "alb.ingress.kubernetes.io/target-type": Config.INGRESS_TARGET_TYPE,
                    # Health check to a valid endpoint
                    "alb.ingress.kubernetes.io/healthcheck-path": "/health",
                    "alb.ingress.kubernetes.io/healthcheck-protocol": "HTTP",
                    "alb.ingress.kubernetes.io/success-codes": "200",
                },
                labels={
                    "app": "openclaw-instances-keeper",
                    "managed-by": "openclaw-provisioning",
                }
            ),
            spec=client.V1IngressSpec(
                ingress_class_name=Config.INGRESS_CLASS,
                rules=[
                    client.V1IngressRule(
                        http=client.V1HTTPIngressRuleValue(
                            paths=[
                                client.V1HTTPIngressPath(
                                    path="/_alb_healthcheck",
                                    path_type="Exact",
                                    backend=client.V1IngressBackend(
                                        service=client.V1IngressServiceBackend(
                                            name="openclaw-provisioning",
                                            port=client.V1ServiceBackendPort(
                                                number=80
                                            )
                                        )
                                    )
                                )
                            ]
                        )
                    )
                ]
            )
        )

        v1.create_namespaced_ingress(
            namespace=keeper_namespace,
            body=ingress
        )

        logger.info(f"✅ Keeper ingress '{keeper_name}' created successfully")
        logger.info(f"   Group name: {Config.INGRESS_GROUP_NAME}")
        logger.info(f"   Scheme: {Config.INGRESS_SCHEME}")

    except Exception as e:
        logger.error(f"❌ Failed to ensure keeper ingress: {str(e)}", exc_info=True)
        # Don't raise - this is not critical for service startup
        # User instances can still be created, they just won't share an ALB initially
