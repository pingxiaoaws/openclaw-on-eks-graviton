"""Application configuration"""
import os

class Config:
    """Application configuration"""

    # Flask
    SECRET_KEY = os.environ.get('SECRET_KEY', 'dev-secret-key-change-in-production')
    DEBUG = os.environ.get('DEBUG', 'false').lower() == 'true'

    # Kubernetes
    K8S_NAMESPACE_PREFIX = 'openclaw'

    # OpenClaw Instance 默认配置
    OPENCLAW_DEFAULTS = {
        'runtime_class': 'kata-fc',
        'node_selector': {'workload-type': 'kata'},
        'tolerations': [
            {
                'key': 'kata-dedicated',
                'operator': 'Exists',
                'effect': 'NoSchedule'
            }
        ],
        'resources': {
            'requests': {'cpu': '600m', 'memory': '1.2Gi'},
            'limits': {'cpu': '2', 'memory': '4Gi'}
        },
        'storage_size': '10Gi',
        'storage_class': 'gp3',
        'model': 'bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0',
        'aws_credentials_secret': 'aws-credentials'
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
