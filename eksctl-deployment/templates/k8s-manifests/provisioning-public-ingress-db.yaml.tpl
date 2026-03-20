apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openclaw-provisioning-public
  namespace: openclaw-provisioning
  annotations:
    alb.ingress.kubernetes.io/group.name: ${SHARED_ALB_GROUP}
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/subnets: ${PUBLIC_SUBNETS}
    alb.ingress.kubernetes.io/security-groups: ${CLOUDFRONT_SG_ID}
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/success-codes: "200"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/target-group-attributes: >-
      stickiness.enabled=true,
      stickiness.type=lb_cookie,
      stickiness.lb_cookie.duration_seconds=3600,
      deregistration_delay.timeout_seconds=60,
      load_balancing.algorithm.type=least_outstanding_requests
  labels:
    app: openclaw-provisioning
    managed-by: deployment-script
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /login
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /logout
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /me
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /dashboard
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /static
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /provision
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /status
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /delete
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /health
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /register
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /billing
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /admin
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /devices
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /instance
        pathType: Prefix
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
      - path: /
        pathType: Exact
        backend:
          service:
            name: openclaw-provisioning
            port:
              number: 80
