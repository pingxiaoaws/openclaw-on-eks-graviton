"""Delete API endpoint"""
from flask import Blueprint, jsonify, current_app
from app.k8s.client import K8sClient
from app.utils.jwt_auth import require_auth
from app.utils.user_id import generate_user_id
from kubernetes.client.rest import ApiException
import logging

delete_bp = Blueprint('delete', __name__)
logger = logging.getLogger(__name__)

@delete_bp.route('/delete/<user_id>', methods=['DELETE'])
@require_auth(lambda: current_app.jwt_verifier)
def delete(user_info, user_id):
    """
    Delete an OpenClaw instance and its namespace

    Authentication: Requires valid JWT token in Authorization header
    Authorization: Users can only delete their own instances

    Args:
        user_id: User ID

    Response (200 OK):
    {
        "status": "deleted",
        "user_id": "7ec7606c",
        "message": "Instance deleted successfully"
    }

    Response (403 Forbidden):
    {
        "error": "Forbidden: You can only delete your own instances"
    }

    Response (404 Not Found):
    {
        "error": "Instance not found"
    }
    """
    try:
        # Verify user can only delete their own instance
        authenticated_user_id = generate_user_id(user_info['user_email'])
        if user_id != authenticated_user_id:
            logger.warning(f"⚠️ Unauthorized delete attempt: {user_info['user_email']} tried to delete user_id {user_id}")
            return jsonify({
                "error": "Forbidden: You can only delete your own instances"
            }), 403

        namespace = f"openclaw-{user_id}"

        logger.info(f"🗑️  Delete request for user: {user_id} ({user_info['user_email']})")

        k8s_client = K8sClient()

        # Delete namespace (will cascade delete all resources)
        k8s_client.core_v1.delete_namespace(
            name=namespace,
            body={}
        )

        logger.info(f"✅ Deleted namespace: {namespace}")

        return jsonify({
            "status": "deleted",
            "user_id": user_id,
            "namespace": namespace,
            "message": "Instance deleted successfully"
        }), 200

    except ApiException as e:
        if e.status == 404:
            return jsonify({"error": "Instance not found"}), 404
        logger.error(f"❌ Error deleting instance: {str(e)}")
        return jsonify({"error": str(e)}), 500
    except Exception as e:
        logger.error(f"❌ Error deleting instance: {str(e)}", exc_info=True)
        return jsonify({"error": str(e)}), 500
