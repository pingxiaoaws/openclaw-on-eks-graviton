"""Main Flask application"""
from flask import Flask, render_template, send_from_directory
from kubernetes import config
import logging
import os

logger = logging.getLogger(__name__)

def create_app():
    """Factory function to create Flask application"""
    # Set template and static folders
    template_dir = os.path.join(os.path.dirname(__file__), 'templates')
    static_dir = os.path.join(os.path.dirname(__file__), 'static')

    app = Flask(__name__,
                template_folder=template_dir,
                static_folder=static_dir)

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

    # Register blueprints (API endpoints)
    from app.api import provision_bp, status_bp, delete_bp, health_bp
    app.register_blueprint(provision_bp)
    app.register_blueprint(status_bp)
    app.register_blueprint(delete_bp)
    app.register_blueprint(health_bp)

    # Frontend routes
    @app.route('/')
    def index():
        """Serve frontend dashboard"""
        return render_template('index.html')

    @app.route('/dashboard')
    def dashboard():
        """Alias for index"""
        return render_template('index.html')

    # Serve static files explicitly (for cases where static_folder doesn't work)
    @app.route('/static/<path:filename>')
    def serve_static(filename):
        """Serve static files"""
        return send_from_directory(app.static_folder, filename)

    # Setup middlewares
    from app.middleware import setup_middlewares
    setup_middlewares(app)

    logger.info("🚀 OpenClaw Provisioning Service initialized")
    logger.info(f"📁 Template folder: {template_dir}")
    logger.info(f"📁 Static folder: {static_dir}")
    return app

# Create app instance
app = create_app()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=app.config['DEBUG'])
