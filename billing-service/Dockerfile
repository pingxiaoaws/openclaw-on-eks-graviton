FROM python:3.12-slim
RUN pip install --no-cache-dir psycopg2-binary
COPY billing-sidecar.py /app/billing-sidecar.py
USER 1000
ENTRYPOINT ["python3", "/app/billing-sidecar.py"]
