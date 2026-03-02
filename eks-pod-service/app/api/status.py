"""Status API endpoint"""
from flask import Blueprint, jsonify, current_app
from app.k8s.client import K8sClient
from app.utils.jwt_auth import require_auth
from app.utils.user_id import generate_user_id
from kubernetes.client.rest import ApiException
import logging

status_bp = Blueprint('status', __name__)
logger = logging.getLogger(__name__)

@status_bp.route('/status/<user_id>', methods=['GET'])
@require_auth(lambda: current_app.jwt_verifier)
def status(user_info, user_id):
    """
    Get OpenClaw instance status

    Authentication: Requires valid JWT token in Authorization header
    Authorization: Users can only access their own instances

    Args:
        user_id: User ID

    Response (200 OK):
    {
        "user_id": "7ec7606c",
        "namespace": "openclaw-7ec7606c",
        "instance_name": "openclaw-7ec7606c",
        "status": {
            "phase": "Running",
            "conditions": [...]
        }
    }

    Response (403 Forbidden):
    {
        "error": "Forbidden: You can only access your own instances"
    }

    Response (404 Not Found):
    {
        "error": "Instance not found"
    }
    """
    try:
        # Verify user can only access their own instance
        authenticated_user_id = generate_user_id(user_info['user_email'])
        if user_id != authenticated_user_id:
            logger.warning(f"⚠️ Unauthorized access attempt: {user_info['user_email']} tried to access user_id {user_id}")
            return jsonify({
                "error": "Forbidden: You can only access your own instances"
            }), 403

        namespace = f"openclaw-{user_id}"
        instance_name = f"openclaw-{user_id}"

        k8s_client = K8sClient()

        # Get OpenClawInstance CRD
        instance = k8s_client.custom_objects.get_namespaced_custom_object(
            group="openclaw.rocks",
            version="v1alpha1",
            namespace=namespace,
            plural="openclawinstances",
            name=instance_name
        )

        # Get Pod status
        try:
            pods = k8s_client.core_v1.list_namespaced_pod(
                namespace=namespace,
                label_selector=f"app.kubernetes.io/instance={instance_name}"
            )
            pod_status = []
            for pod in pods.items:
                pod_status.append({
                    "name": pod.metadata.name,
                    "phase": pod.status.phase,
                    "ready": all(cs.ready for cs in pod.status.container_statuses) if pod.status.container_statuses else False
                })
        except:
            pod_status = []

        # Extract status from OpenClawInstance
        instance_status = instance.get('status', {})
        phase = instance_status.get('phase', 'Pending')
        gateway_endpoint = instance_status.get('gatewayEndpoint', '')

        # Get creation timestamp
        created_at = instance.get('metadata', {}).get('creationTimestamp', '')

        # Build external Ingress URL if enabled
        from app.config import Config
        ingress_url = None
        if Config.INGRESS_ENABLED and phase == 'Running':
            protocol = 'https' if Config.INGRESS_CERTIFICATE_ARN else 'http'
            ingress_url = f"{protocol}://{Config.INGRESS_HOST}/instance/{user_id}/"

        response = {
            "user_id": user_id,
            "namespace": namespace,
            "instance_name": instance_name,
            "status": phase,  # Simple string: "Running", "Pending", etc.
            "gateway_endpoint": gateway_endpoint,  # Internal cluster endpoint
            "ingress_url": ingress_url,  # External Ingress URL
            "created_at": created_at,
            "pods": pod_status,
            "raw_status": instance_status  # Keep full status for debugging
        }

        return jsonify(response), 200

    except ApiException as e:
        if e.status == 404:
            return jsonify({"error": "Instance not found"}), 404
        logger.error(f"❌ Error getting status: {str(e)}")
        return jsonify({"error": str(e)}), 500
    except Exception as e:
        logger.error(f"❌ Error getting status: {str(e)}", exc_info=True)
        return jsonify({"error": str(e)}), 500
