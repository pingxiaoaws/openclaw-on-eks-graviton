apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw-provisioning
  namespace: openclaw-provisioning
  labels:
    app: openclaw-provisioning
spec:
  replicas: 1
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
        - name: OPENCLAW_IMAGE_REPOSITORY
          value: "${OPENCLAW_IMG_REPO}"
        - name: OPENCLAW_IMAGE_TAG
          value: "${OPENCLAW_IMG_TAG}"
        # PostgreSQL Configuration
        - name: POSTGRES_HOST
          value: "postgres"
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: POSTGRES_DB
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: POSTGRES_PASSWORD
        resources:
          requests:
            cpu: 250m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
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
