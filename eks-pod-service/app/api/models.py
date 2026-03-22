"""Models API endpoint"""
from flask import Blueprint, jsonify
from app.config import Config

models_bp = Blueprint('models', __name__)


@models_bp.route('/models', methods=['GET'])
def list_models():
    """Return available Bedrock models (public, no auth required)"""
    return jsonify({"models": Config.BEDROCK_MODELS})
