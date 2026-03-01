"""NetworkPolicy operations"""
from kubernetes import client
import logging

logger = logging.getLogger(__name__)

def create_network_policy(k8s_client, namespace):
    """
    Create a NetworkPolicy in the namespace

    Args:
        k8s_client: K8sClient instance
        namespace: Namespace name

    Returns:
        Tuple of (netpol, created)
    """
    netpol = client.V1NetworkPolicy(
        metadata=client.V1ObjectMeta(name="openclaw-netpol"),
        spec=client.V1NetworkPolicySpec(
            pod_selector=client.V1LabelSelector(
                match_labels={"app.kubernetes.io/component": "openclaw"}
            ),
            policy_types=["Ingress", "Egress"],
            ingress=[
                client.V1NetworkPolicyIngressRule(
                    _from=[
                        client.V1NetworkPolicyPeer(
                            namespace_selector=client.V1LabelSelector(
                                match_labels={"kubernetes.io/metadata.name": "ingress-nginx"}
                            )
                        )
                    ],
                    ports=[
                        client.V1NetworkPolicyPort(protocol="TCP", port=18789)
                    ]
                )
            ],
            egress=[
                # DNS
                client.V1NetworkPolicyEgressRule(
                    to=[client.V1NetworkPolicyPeer(namespace_selector=client.V1LabelSelector())],
                    ports=[
                        client.V1NetworkPolicyPort(protocol="TCP", port=53),
                        client.V1NetworkPolicyPort(protocol="UDP", port=53)
                    ]
                ),
                # HTTPS
                client.V1NetworkPolicyEgressRule(
                    to=[client.V1NetworkPolicyPeer(ip_block=client.V1IPBlock(cidr="0.0.0.0/0"))],
                    ports=[client.V1NetworkPolicyPort(protocol="TCP", port=443)]
                )
            ]
        )
    )

    def create():
        return k8s_client.networking_v1.create_namespaced_network_policy(
            namespace=namespace,
            body=netpol
        )

    def get():
        return k8s_client.networking_v1.read_namespaced_network_policy(
            name="openclaw-netpol",
            namespace=namespace
        )

    return k8s_client.create_or_get(create, get, f"NetworkPolicy in {namespace}")
