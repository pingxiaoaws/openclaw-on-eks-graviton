"""
ALB Waiter Lambda Function

This Lambda function polls the ELB API to wait for an ALB to be created by the
ALB Controller. It filters ALBs by the cluster tag and returns the DNS name and ARN.
"""

import json
import boto3
import time
import urllib3

elbv2_client = boto3.client('elbv2')
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


def find_alb_by_cluster_tag(cluster_name):
    """Find ALB by cluster tag"""
    print(f"Searching for ALB with tag elbv2.k8s.aws/cluster={cluster_name}")

    # Get all load balancers
    paginator = elbv2_client.get_paginator('describe_load_balancers')
    for page in paginator.paginate():
        for alb in page['LoadBalancers']:
            if alb['Type'] != 'application':
                continue

            alb_arn = alb['LoadBalancerArn']
            print(f"Checking ALB: {alb_arn}")

            # Get tags for this ALB
            try:
                tags_response = elbv2_client.describe_tags(ResourceArns=[alb_arn])

                for tag_desc in tags_response['TagDescriptions']:
                    for tag in tag_desc['Tags']:
                        if tag['Key'] == 'elbv2.k8s.aws/cluster' and tag['Value'] == cluster_name:
                            print(f"Found matching ALB: {alb_arn}")
                            print(f"DNS Name: {alb['DNSName']}")

                            # Verify ALB is active
                            if alb['State']['Code'] == 'active':
                                return {
                                    'AlbArn': alb_arn,
                                    'AlbDnsName': alb['DNSName'],
                                    'AlbState': alb['State']['Code']
                                }
                            else:
                                print(f"ALB found but not active yet: {alb['State']['Code']}")
                                return None

            except Exception as e:
                print(f"Error getting tags for {alb_arn}: {str(e)}")
                continue

    return None


def lambda_handler(event, context):
    """Main handler"""
    print(f"Received event: {json.dumps(event)}")

    request_type = event['RequestType']
    props = event['ResourceProperties']

    try:
        if request_type == 'Delete':
            print("Delete request - nothing to do")
            send_response(event, context, 'SUCCESS', {
                'PhysicalResourceId': 'alb-waiter'
            })
            return

        cluster_name = props['ClusterName']
        max_attempts = int(props.get('MaxAttempts', 10))  # 10 attempts = 5 minutes
        interval_seconds = int(props.get('IntervalSeconds', 30))

        print(f"Waiting for ALB for cluster: {cluster_name}")
        print(f"Max attempts: {max_attempts}, Interval: {interval_seconds}s")

        for attempt in range(1, max_attempts + 1):
            print(f"Attempt {attempt}/{max_attempts}")

            alb_info = find_alb_by_cluster_tag(cluster_name)

            if alb_info:
                print("ALB found and active!")
                send_response(event, context, 'SUCCESS', {
                    'PhysicalResourceId': alb_info['AlbArn'],
                    'AlbArn': alb_info['AlbArn'],
                    'AlbDnsName': alb_info['AlbDnsName'],
                    'AlbState': alb_info['AlbState']
                })
                return

            if attempt < max_attempts:
                print(f"ALB not found or not active yet, waiting {interval_seconds}s...")
                time.sleep(interval_seconds)

        # Timeout - ALB not found
        error_msg = f"ALB not found after {max_attempts} attempts ({max_attempts * interval_seconds}s)"
        print(error_msg)
        send_response(event, context, 'FAILED', reason=error_msg)

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
            'ClusterName': 'test-cluster',
            'MaxAttempts': '3',
            'IntervalSeconds': '5'
        },
        'ResponseURL': 'http://localhost:8000',
        'StackId': 'test-stack',
        'RequestId': 'test-request',
        'LogicalResourceId': 'test-resource'
    }

    class TestContext:
        log_stream_name = 'test-log-stream'

    lambda_handler(test_event, TestContext())
