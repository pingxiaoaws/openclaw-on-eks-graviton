"""Application configuration"""
import os
import json

def _parse_json_env(key, default):
    """Parse JSON from environment variable"""
    value = os.environ.get(key)
    if not value:
        return default
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return default

class Config:
    """Application configuration"""

    # Flask
    SECRET_KEY = os.environ.get('SECRET_KEY', 'dev-secret-key-change-in-production')
    DEBUG = os.environ.get('DEBUG', 'false').lower() == 'true'

    # Kubernetes
    K8S_NAMESPACE_PREFIX = 'openclaw'

    # OpenClaw Instance 默认配置 (支持环境变量覆盖)
    OPENCLAW_DEFAULTS = {
        'runtime_class': os.environ.get('OPENCLAW_RUNTIME_CLASS') or None,
        'node_selector': _parse_json_env('OPENCLAW_NODE_SELECTOR', {}),
        'tolerations': _parse_json_env('OPENCLAW_TOLERATIONS', []),
        'resources': {
            'requests': {
                'cpu': os.environ.get('OPENCLAW_CPU_REQUEST', '600m'),
                'memory': os.environ.get('OPENCLAW_MEMORY_REQUEST', '1.2Gi')
            },
            'limits': {
                'cpu': os.environ.get('OPENCLAW_CPU_LIMIT', '2'),
                'memory': os.environ.get('OPENCLAW_MEMORY_LIMIT', '4Gi')
            }
        },
        'storage_size': os.environ.get('OPENCLAW_STORAGE_SIZE', '10Gi'),
        'storage_class': os.environ.get('OPENCLAW_STORAGE_CLASS', 'gp3'),
        'model': os.environ.get('OPENCLAW_MODEL', 'bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0'),
        'aws_credentials_secret': os.environ.get('OPENCLAW_AWS_CREDENTIALS_SECRET', 'aws-credentials')
    }

    # ResourceQuota 限制
    RESOURCE_QUOTA = {
        'requests.cpu': '2',
        'requests.memory': '4Gi',
        'limits.cpu': '4',
        'limits.memory': '8Gi',
        'persistentvolumeclaims': '2'
    }

    # 超时设置
    K8S_API_TIMEOUT = 30

    # 日志
    LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')

    # Cognito JWT 验证配置
    COGNITO_REGION = os.environ.get('COGNITO_REGION', 'us-west-2')
    COGNITO_USER_POOL_ID = os.environ.get('COGNITO_USER_POOL_ID', 'us-west-2_gvOCTiLQE')
    COGNITO_CLIENT_ID = os.environ.get('COGNITO_CLIENT_ID', 'f5qd2udi8508dd132d72qn7uc')
    COGNITO_USER_POOL_DOMAIN = os.environ.get('COGNITO_USER_POOL_DOMAIN', '')  # e.g., your-domain.auth.us-west-2.amazoncognito.com
    AWS_ACCOUNT_ID = os.environ.get('AWS_ACCOUNT_ID', '')  # AWS Account ID for Cognito ARN

    # Ingress 配置（用于 OpenClaw instance 外部访问）
    INGRESS_ENABLED = os.environ.get('INGRESS_ENABLED', 'true').lower() == 'true'
    INGRESS_CLASS = os.environ.get('INGRESS_CLASS', 'alb')
    INGRESS_HOST = os.environ.get('INGRESS_HOST', 'openclaw.example.com')  # 需要配置真实域名
    INGRESS_GROUP_NAME = os.environ.get('INGRESS_GROUP_NAME', 'openclaw-instances')
    INGRESS_SCHEME = os.environ.get('INGRESS_SCHEME', 'internet-facing')
    INGRESS_CERTIFICATE_ARN = os.environ.get('INGRESS_CERTIFICATE_ARN', '')  # ACM 证书 ARN（可选）
