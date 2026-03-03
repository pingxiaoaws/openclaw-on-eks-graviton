"""Main Flask application"""
from flask import Flask, render_template, send_from_directory
from kubernetes import config
import logging
import os

logger = logging.getLogger(__name__)

class StripProdPrefixMiddleware:
    """WSGI Middleware to strip /prod prefix before Flask routing"""
    def __init__(self, app):
        self.app = app

    def __call__(self, environ, start_response):
        path = environ.get('PATH_INFO', '')
        if path.startswith('/prod/'):
            environ['PATH_INFO'] = path[5:]  # Remove '/prod'
            logger.debug(f"Stripped /prod prefix: {path} -> {environ['PATH_INFO']}")
        return self.app(environ, start_response)

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

    # Initialize JWT Verifier for Cognito authentication
    from app.utils.jwt_auth import CognitoJWTVerifier
    jwt_verifier = CognitoJWTVerifier(
        region=app.config['COGNITO_REGION'],
        user_pool_id=app.config['COGNITO_USER_POOL_ID'],
        client_id=app.config['COGNITO_CLIENT_ID']
    )
    # Store verifier in app context for access in blueprints
    app.jwt_verifier = jwt_verifier
    logger.info("✅ Cognito JWT verifier initialized")

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

    # Ensure keeper ingress exists (for shared ALB)
    from app.k8s.ingress import ensure_keeper_ingress
    ensure_keeper_ingress()

    # Register blueprints (API endpoints)
    from app.api import provision_bp, status_bp, delete_bp, health_bp, proxy_bp
    app.register_blueprint(provision_bp)
    app.register_blueprint(status_bp)
    app.register_blueprint(delete_bp)
    app.register_blueprint(health_bp)
    app.register_blueprint(proxy_bp)  # Reverse proxy for instance access

    # Frontend routes
    @app.route('/')
    def index():
        """Redirect to login page"""
        from flask import redirect
        return redirect('/login')

    @app.route('/login')
    def login():
        """Serve login page"""
        return render_template('login-new.html')

    @app.route('/dashboard')
    def dashboard():
        """Serve dashboard page"""
        return render_template('dashboard-new.html')

    @app.route('/test')
    def test_dashboard():
        """Serve test dashboard (no auth required)"""
        return render_template('dashboard-test.html')

    # Serve static files explicitly (for cases where static_folder doesn't work)
    @app.route('/static/<path:filename>')
    def serve_static(filename):
        """Serve static files"""
        return send_from_directory(app.static_folder, filename)

    # Setup middlewares
    from app.middleware import setup_middlewares
    setup_middlewares(app)

    # Apply WSGI middleware to strip /prod prefix (must be last)
    app.wsgi_app = StripProdPrefixMiddleware(app.wsgi_app)

    logger.info("🚀 OpenClaw Provisioning Service initialized")
    logger.info(f"📁 Template folder: {template_dir}")
    logger.info(f"📁 Static folder: {static_dir}")
    return app

# Create app instance
app = create_app()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=app.config['DEBUG'])
