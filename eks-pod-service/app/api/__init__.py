"""API endpoints"""
from flask import Blueprint

# Import blueprints
from app.api.provision import provision_bp
from app.api.status import status_bp
from app.api.delete import delete_bp
from app.api.health import health_bp
from app.api.proxy import proxy_bp

__all__ = ['provision_bp', 'status_bp', 'delete_bp', 'health_bp', 'proxy_bp']
