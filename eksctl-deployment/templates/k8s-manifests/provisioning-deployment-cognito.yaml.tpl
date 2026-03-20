apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-provisioning
  namespace: openclaw-provisioning
  labels:
    app: openclaw-provisioning
spec:
  replicas: 2
  selector:
    matchLabels:
      app: openclaw-provisioning
  template:
    metadata:
      labels:
        app: openclaw-provisioning
    spec:
      serviceAccountName: openclaw-provisioner
      containers:
      - name: provisioning
        image: ${PROVISIONING_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: LOG_LEVEL
          value: "INFO"
        - name: USE_POD_IDENTITY
          value: "true"
        - name: SHARED_BEDROCK_ROLE_ARN
          value: "${BEDROCK_ROLE_ARN}"
        - name: EKS_CLUSTER_NAME
          value: "${CLUSTER_NAME}"
        - name: AWS_REGION
          value: "${AWS_REGION}"
        - name: AWS_ACCOUNT_ID
          value: "${AWS_ACCOUNT}"
        - name: COGNITO_REGION
          value: "${AWS_REGION}"
        - name: COGNITO_USER_POOL_ID
          value: "${USER_POOL_ID}"
        - name: COGNITO_CLIENT_ID
          value: "${USER_POOL_CLIENT_ID}"
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
