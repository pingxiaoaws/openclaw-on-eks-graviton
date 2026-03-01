"""Main Flask application"""
from flask import Flask
from kubernetes import config
import logging

logger = logging.getLogger(__name__)

def create_app():
    """Factory function to create Flask application"""
    app = Flask(__name__)

    # Load configuration
    app.config.from_object('app.config.Config')

    # Initialize Kubernetes client (in-cluster)
    try:
        config.load_incluster_config()
        logger.info("✅ Kubernetes in-cluster config loaded")
    except config.ConfigException:
        # Fallback to kubeconfig (for local development)
        try:
            config.load_kube_config()
            logger.info("✅ Kubernetes kubeconfig loaded (dev mode)")
        except Exception as e:
            logger.error(f"❌ Failed to load Kubernetes config: {e}")
            raise

    # Register blueprints
    from app.api import provision_bp, status_bp, delete_bp, health_bp
    app.register_blueprint(provision_bp)
    app.register_blueprint(status_bp)
    app.register_blueprint(delete_bp)
    app.register_blueprint(health_bp)

    # Setup middlewares
    from app.middleware import setup_middlewares
    setup_middlewares(app)

    logger.info("🚀 OpenClaw Provisioning Service initialized")
    return app

# Create app instance
app = create_app()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=app.config['DEBUG'])
