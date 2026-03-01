"""Middleware configuration"""
from app.middleware.logging import setup_logging
from app.middleware.error_handler import setup_error_handlers

def setup_middlewares(app):
    """Setup all middlewares"""
    setup_logging(app)
    setup_error_handlers(app)
