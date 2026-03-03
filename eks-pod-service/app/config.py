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

    # AWS 配置
    AWS_REGION = os.environ.get('AWS_REGION', 'us-west-2')
    AWS_ACCOUNT_ID = os.environ.get('AWS_ACCOUNT_ID', '')  # AWS Account ID for Cognito ARN

    # EKS 配置
    EKS_CLUSTER_NAME = os.environ.get('EKS_CLUSTER_NAME', 'test-s4')
    USE_POD_IDENTITY = os.environ.get('USE_POD_IDENTITY', 'true').lower() == 'true'

    # Cognito JWT 验证配置
    COGNITO_REGION = os.environ.get('COGNITO_REGION', 'us-west-2')
    COGNITO_USER_POOL_ID = os.environ.get('COGNITO_USER_POOL_ID', 'us-west-2_gvOCTiLQE')
    COGNITO_CLIENT_ID = os.environ.get('COGNITO_CLIENT_ID', '7hu644gbgodv2bap8cq6eb02n7')  # No secret
    COGNITO_USER_POOL_DOMAIN = os.environ.get('COGNITO_USER_POOL_DOMAIN', '')  # e.g., your-domain.auth.us-west-2.amazoncognito.com

    # Ingress 配置（Internal ALB + API Gateway）
    INGRESS_ENABLED = os.environ.get('INGRESS_ENABLED', 'true').lower() == 'true'
    INGRESS_CLASS = os.environ.get('INGRESS_CLASS', 'alb')
    INGRESS_GROUP_NAME = os.environ.get('INGRESS_GROUP_NAME', 'openclaw-shared-instances')
    INGRESS_SCHEME = os.environ.get('INGRESS_SCHEME', 'internal')  # Internal ALB（不暴露公网）
    INGRESS_TARGET_TYPE = os.environ.get('INGRESS_TARGET_TYPE', 'ip')  # IP mode for better performance

    # API Gateway 配置（用于构建外部访问 URL）
    API_GATEWAY_ENDPOINT = os.environ.get('API_GATEWAY_ENDPOINT', 'https://0qu1ls4sf5.execute-api.us-west-2.amazonaws.com')
    API_GATEWAY_STAGE = os.environ.get('API_GATEWAY_STAGE', 'prod')
