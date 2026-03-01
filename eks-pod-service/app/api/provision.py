"""Provision API endpoint"""
from flask import Blueprint, request, jsonify
from app.k8s.client import K8sClient
from app.k8s.namespace import create_namespace
from app.k8s.quota import create_resource_quota
from app.k8s.netpol import create_network_policy
from app.k8s.instance import create_openclaw_instance
from app.utils.user_id import generate_user_id
from app.utils.validator import validate_email
import logging

provision_bp = Blueprint('provision', __name__)
logger = logging.getLogger(__name__)

@provision_bp.route('/provision', methods=['POST'])
def provision():
    """
    Create an OpenClaw instance

    Request Body:
    {
        "email": "user@example.com",
        "cognito_sub": "xxx-xxx-xxx",  # optional
        "config": {  # optional, overrides defaults
            "resources": {
                "requests": {"cpu": "1", "memory": "2Gi"}
            }
        }
    }

    Response (201 Created):
    {
        "status": "created",
        "user_id": "7ec7606c",
        "namespace": "openclaw-7ec7606c",
        "instance_name": "openclaw-7ec7606c",
        "gateway_endpoint": "openclaw-7ec7606c.openclaw-7ec7606c.svc:18789",
        "message": "Instance created successfully"
    }

    Response (200 OK) - if already exists:
    {
        "status": "exists",
        ...
    }
    """
    try:
        # Validate input
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body is required"}), 400

        user_email = data.get('email')
        if not user_email or not validate_email(user_email):
            return jsonify({"error": "Valid email is required"}), 400

        cognito_sub = data.get('cognito_sub')
        custom_config = data.get('config', {})

        # Generate user_id
        user_id = generate_user_id(user_email)
        namespace = f"openclaw-{user_id}"
        instance_name = f"openclaw-{user_id}"

        logger.info(f"📥 Provisioning request: {user_email} (user_id: {user_id})")

        # Initialize K8s client
        k8s_client = K8sClient()

        # Create Namespace
        ns, ns_created = create_namespace(k8s_client, user_id)

        # Create ResourceQuota
        quota, quota_created = create_resource_quota(k8s_client, namespace)

        # Create NetworkPolicy
        netpol, netpol_created = create_network_policy(k8s_client, namespace)

        # Create OpenClawInstance
        instance, instance_created = create_openclaw_instance(
            k8s_client,
            user_id,
            namespace,
            user_email,
            cognito_sub,
            custom_config
        )

        # Build response
        status = "created" if instance_created else "exists"
        gateway_endpoint = f"{instance_name}.{namespace}.svc:18789"

        response = {
            "status": status,
            "user_id": user_id,
            "namespace": namespace,
            "instance_name": instance_name,
            "gateway_endpoint": gateway_endpoint,
            "message": f"Instance {status} successfully",
            "resources_created": {
                "namespace": ns_created,
                "resource_quota": quota_created,
                "network_policy": netpol_created,
                "openclaw_instance": instance_created
            }
        }

        status_code = 201 if instance_created else 200
        logger.info(f"✅ Provisioning completed: {user_email} ({status})")

        return jsonify(response), status_code

    except Exception as e:
        logger.error(f"❌ Error provisioning instance: {str(e)}", exc_info=True)
        return jsonify({"error": str(e)}), 500
