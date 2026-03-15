"""Reverse proxy API endpoint for OpenClaw instances"""
from flask import Blueprint, request, Response, current_app
from app.k8s.client import K8sClient
from app.utils.session_auth import require_auth
from app.utils.user_id import generate_user_id
import requests
import logging

proxy_bp = Blueprint('proxy', __name__)
logger = logging.getLogger(__name__)

def proxy_to_instance(user_info, user_id, subpath):
    """
    Reverse proxy to OpenClaw instance gateway

    This endpoint dynamically routes requests to the correct OpenClaw instance
    based on the user_id in the URL path. No per-user configuration needed!

    Authentication:
    - Requires valid JWT token OR gateway token
    - JWT: from Authorization header (for dashboard access)
    - Gateway token: from ?token=xxx query parameter (for direct access)

    Example:
        GET /instance/416e0b5f/workspace/abc123
        → Proxies to http://openclaw-416e0b5f.openclaw-416e0b5f.svc:18789/workspace/abc123

    Args:
        user_id: User ID (first 8 chars of email hash)
        subpath: Path to proxy to the instance (e.g., "workspace/abc123")
    """
    try:
        # Build target URL
        namespace = f"openclaw-{user_id}"
        service_name = f"openclaw-{user_id}"
        service_port = 18789

        # Kubernetes internal DNS: service.namespace.svc.cluster.local
        target_url = f"http://{service_name}.{namespace}.svc.cluster.local:{service_port}/{subpath}"

        # Preserve query parameters
        if request.query_string:
            target_url += f"?{request.query_string.decode('utf-8')}"

        logger.info(f"🔀 Proxying {request.method} {request.path} → {target_url}")

        # Forward request headers (exclude hop-by-hop headers)
        headers = {}
        for key, value in request.headers:
            if key.lower() not in ['host', 'connection', 'keep-alive', 'proxy-authenticate',
                                   'proxy-authorization', 'te', 'trailers', 'transfer-encoding', 'upgrade']:
                headers[key] = value

        # Forward the request to OpenClaw instance
        response = requests.request(
            method=request.method,
            url=target_url,
            headers=headers,
            data=request.get_data(),
            cookies=request.cookies,
            allow_redirects=False,
            timeout=30,
            stream=True  # Stream response for large files
        )

        # Build response
        excluded_headers = ['content-encoding', 'content-length', 'transfer-encoding', 'connection']
        response_headers = [
            (name, value) for (name, value) in response.raw.headers.items()
            if name.lower() not in excluded_headers
        ]

        logger.info(f"✅ Proxied response: {response.status_code}")

        return Response(
            response.iter_content(chunk_size=8192),
            status=response.status_code,
            headers=response_headers,
            direct_passthrough=True
        )

    except requests.exceptions.ConnectionError as e:
        logger.error(f"❌ Connection error to instance: {str(e)}")
        return {
            "error": "Instance not reachable",
            "message": "The OpenClaw instance is not responding. It may still be starting up.",
            "user_id": user_id
        }, 503
    except requests.exceptions.Timeout as e:
        logger.error(f"❌ Timeout connecting to instance: {str(e)}")
        return {
            "error": "Request timeout",
            "message": "The OpenClaw instance did not respond in time.",
            "user_id": user_id
        }, 504
    except Exception as e:
        logger.error(f"❌ Error proxying request: {str(e)}", exc_info=True)
        return {
            "error": "Proxy error",
            "message": str(e),
            "user_id": user_id
        }, 500


@proxy_bp.route('/instance/<user_id>/', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'])
@proxy_bp.route('/instance/<user_id>', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'])
def proxy_to_instance_root(user_id):
    """
    Proxy to OpenClaw instance root path

    This handles the case when accessing /instance/{user_id}/ or /instance/{user_id}
    """
    # Pass empty user_info since we don't do auth here (OpenClaw Gateway handles it)
    user_info = {}
    return proxy_to_instance(user_info, user_id, '')


# Register proxy routes with main subpath handler
@proxy_bp.route('/instance/<user_id>/<path:subpath>', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'])
def proxy_with_subpath(user_id, subpath):
    """Route handler with subpath"""
    user_info = {}
    return proxy_to_instance(user_info, user_id, subpath)
