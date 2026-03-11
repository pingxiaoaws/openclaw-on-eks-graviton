"""
Cognito User Lambda Function

This Lambda function creates a Cognito user with a secure random password
and stores the password in AWS Secrets Manager.
"""

import json
import boto3
import secrets
import string
import urllib3

cognito_client = boto3.client('cognito-idp')
secretsmanager_client = boto3.client('secretsmanager')
http = urllib3.PoolManager()


def send_response(event, context, status, data=None, reason=None):
    """Send CloudFormation custom resource response"""
    response_body = {
        'Status': status,
        'PhysicalResourceId': data.get('PhysicalResourceId', context.log_stream_name) if data else context.log_stream_name,
        'StackId': event['StackId'],
        'RequestId': event['RequestId'],
        'LogicalResourceId': event['LogicalResourceId'],
        'Data': data or {},
        'Reason': reason or f"See CloudWatch Log Stream: {context.log_stream_name}"
    }

    print(f"Sending response: {json.dumps(response_body)}")

    try:
        response = http.request(
            'PUT',
            event['ResponseURL'],
            body=json.dumps(response_body).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        print(f"Response status: {response.status}")
    except Exception as e:
        print(f"Error sending response: {str(e)}")


def generate_secure_password(length=20):
    """Generate a secure random password"""
    # Include uppercase, lowercase, digits, and special characters
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*()_+-=[]{}|;:,.<>?"

    # Ensure at least one character from each category
    password = [
        secrets.choice(string.ascii_uppercase),
        secrets.choice(string.ascii_lowercase),
        secrets.choice(string.digits),
        secrets.choice("!@#$%^&*")
    ]

    # Fill the rest randomly
    password.extend(secrets.choice(alphabet) for _ in range(length - 4))

    # Shuffle to avoid predictable patterns
    secrets.SystemRandom().shuffle(password)

    return ''.join(password)


def create_user(user_pool_id, email):
    """Create Cognito user"""
    print(f"Creating user: {email}")

    try:
        response = cognito_client.admin_create_user(
            UserPoolId=user_pool_id,
            Username=email,
            UserAttributes=[
                {'Name': 'email', 'Value': email},
                {'Name': 'email_verified', 'Value': 'true'}
            ],
            MessageAction='SUPPRESS',  # Don't send welcome email
            DesiredDeliveryMediums=['EMAIL']
        )
        print(f"User created: {response['User']['Username']}")
        return True
    except cognito_client.exceptions.UsernameExistsException:
        print(f"User {email} already exists")
        return True
    except Exception as e:
        print(f"Error creating user: {str(e)}")
        raise


def set_user_password(user_pool_id, email, password):
    """Set permanent password for user"""
    print(f"Setting password for user: {email}")

    try:
        cognito_client.admin_set_user_password(
            UserPoolId=user_pool_id,
            Username=email,
            Password=password,
            Permanent=True
        )
        print("Password set successfully")
        return True
    except Exception as e:
        print(f"Error setting password: {str(e)}")
        raise


def store_password_in_secrets_manager(secret_name, password, cluster_name, email):
    """Store password in AWS Secrets Manager"""
    print(f"Storing password in Secrets Manager: {secret_name}")

    try:
        response = secretsmanager_client.create_secret(
            Name=secret_name,
            Description=f"Test user password for OpenClaw cluster {cluster_name}",
            SecretString=password,
            Tags=[
                {'Key': 'ClusterName', 'Value': cluster_name},
                {'Key': 'UserEmail', 'Value': email},
                {'Key': 'ManagedBy', 'Value': 'CloudFormation'}
            ]
        )
        print(f"Secret created: {response['ARN']}")
        return response['ARN']
    except secretsmanager_client.exceptions.ResourceExistsException:
        print(f"Secret {secret_name} already exists, updating...")
        response = secretsmanager_client.update_secret(
            SecretId=secret_name,
            SecretString=password
        )
        # Get ARN
        response = secretsmanager_client.describe_secret(SecretId=secret_name)
        return response['ARN']
    except Exception as e:
        print(f"Error storing password: {str(e)}")
        raise


def delete_user(user_pool_id, email):
    """Delete Cognito user"""
    print(f"Deleting user: {email}")

    try:
        cognito_client.admin_delete_user(
            UserPoolId=user_pool_id,
            Username=email
        )
        print("User deleted successfully")
        return True
    except cognito_client.exceptions.UserNotFoundException:
        print(f"User {email} not found, nothing to delete")
        return True
    except Exception as e:
        print(f"Error deleting user: {str(e)}")
        # Don't fail on delete errors
        return True


def delete_secret(secret_name):
    """Delete secret from Secrets Manager"""
    print(f"Deleting secret: {secret_name}")

    try:
        secretsmanager_client.delete_secret(
            SecretId=secret_name,
            ForceDeleteWithoutRecovery=True
        )
        print("Secret deleted successfully")
        return True
    except secretsmanager_client.exceptions.ResourceNotFoundException:
        print(f"Secret {secret_name} not found, nothing to delete")
        return True
    except Exception as e:
        print(f"Error deleting secret: {str(e)}")
        # Don't fail on delete errors
        return True


def lambda_handler(event, context):
    """Main handler"""
    print(f"Received event: {json.dumps(event)}")

    request_type = event['RequestType']
    props = event['ResourceProperties']

    try:
        user_pool_id = props['UserPoolId']
        email = props['Email']
        cluster_name = props.get('ClusterName', 'openclaw')
        secret_name = props.get('SecretName', f'openclaw/{cluster_name}/test-user-password')

        if request_type == 'Delete':
            print("Delete request - cleaning up user and secret")
            delete_user(user_pool_id, email)
            delete_secret(secret_name)

            send_response(event, context, 'SUCCESS', {
                'PhysicalResourceId': email
            })
            return

        # Create or Update
        print(f"Creating/updating user: {email}")

        # Generate secure password
        password = generate_secure_password()
        print("Secure password generated")

        # Create user
        create_user(user_pool_id, email)

        # Set password
        set_user_password(user_pool_id, email, password)

        # Store password in Secrets Manager
        secret_arn = store_password_in_secrets_manager(secret_name, password, cluster_name, email)

        print("User creation complete!")

        send_response(event, context, 'SUCCESS', {
            'PhysicalResourceId': email,
            'TestUserEmail': email,
            'TestUserPasswordSecretArn': secret_arn,
            'TestUserPasswordSecretName': secret_name
        })

    except Exception as e:
        error_msg = f"Error: {str(e)}"
        print(error_msg)
        import traceback
        traceback.print_exc()
        send_response(event, context, 'FAILED', reason=error_msg)


if __name__ == '__main__':
    # For local testing
    test_event = {
        'RequestType': 'Create',
        'ResourceProperties': {
            'UserPoolId': 'us-west-2_XXXXXXXXX',
            'Email': 'testuser@example.com',
            'ClusterName': 'test-cluster',
            'SecretName': 'openclaw/test-cluster/test-user-password'
        },
        'ResponseURL': 'http://localhost:8000',
        'StackId': 'test-stack',
        'RequestId': 'test-request',
        'LogicalResourceId': 'test-resource'
    }

    class TestContext:
        log_stream_name = 'test-log-stream'

    lambda_handler(test_event, TestContext())
