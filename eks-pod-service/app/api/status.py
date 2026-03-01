"""Status API endpoint"""
from flask import Blueprint, jsonify
from app.k8s.client import K8sClient
from kubernetes.client.rest import ApiException
import logging

status_bp = Blueprint('status', __name__)
logger = logging.getLogger(__name__)

@status_bp.route('/status/<user_id>', methods=['GET'])
def status(user_id):
    """
    Get OpenClaw instance status

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

    Response (404 Not Found):
    {
        "error": "Instance not found"
    }
    """
    try:
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

        response = {
            "user_id": user_id,
            "namespace": namespace,
            "instance_name": instance_name,
            "status": instance.get('status', {}),
            "pods": pod_status
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
