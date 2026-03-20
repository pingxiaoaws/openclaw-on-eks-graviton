apiVersion: openclaw.rocks/v1alpha1
kind: OpenClawInstance
metadata:
  name: ${TEST_INSTANCE_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: bedrock-apikey-setup
spec:
  image:${OPENCLAW_IMAGE_SPEC}
    pullPolicy: IfNotPresent
  config:
    raw:
      gateway:
        controlUi:
          allowedOrigins:
            - "http://localhost:18789"
            - "http://127.0.0.1:18789"
        trustedProxies:
          - "0.0.0.0/0"
      agents:
        defaults:
          model:
            primary: "bedrock/${MODEL_ID}"
  envFrom:
    - secretRef:
        name: ${SECRET_NAME}
  env:
    - name: AWS_REGION
      value: "${AWS_REGION}"
    - name: AWS_DEFAULT_REGION
      value: "${AWS_REGION}"
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
  storage:
    persistence:
      enabled: true
      size: 10Gi
      storageClass: gp3
      accessModes:
        - ReadWriteOnce
  networking:
    service:
      type: ClusterIP
  security:
    podSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      runAsNonRoot: true
    containerSecurityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      capabilities:
        drop:
          - ALL
    networkPolicy:
      enabled: true
      allowDNS: true
    rbac:
      createServiceAccount: true
  selfConfigure:
    enabled: true
  observability:
    metrics:
      enabled: true
      port: 9090
    logging:
      level: info
      format: json
