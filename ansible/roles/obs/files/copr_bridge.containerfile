# Build stage
FROM registry.access.redhat.com/hi/python:latest-builder AS builder
USER root
RUN pip install --no-cache-dir copr coloredlogs
USER ${CONTAINER_DEFAULT_USER}

# Runtime stage
FROM registry.access.redhat.com/hi/python:latest
COPY --from=builder /usr/local/lib/python3.14/site-packages /usr/local/lib/python3.14/site-packages
COPY --from=builder /usr/local/lib64/python3.14/site-packages /usr/local/lib64/python3.14/site-packages
COPY ansible/roles/obs/files/copr_bridge.py /app/copr_bridge.py
ENTRYPOINT ["python3", "/app/copr_bridge.py"]
