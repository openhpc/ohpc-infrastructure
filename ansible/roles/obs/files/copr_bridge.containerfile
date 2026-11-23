# Build stage
FROM registry.access.redhat.com/hi/python:latest-builder AS builder
USER root
# The Python version of the base image changes over time and with it the
# site-packages path. A fixed --target directory keeps the COPY below valid.
RUN pip install --no-cache-dir --target /app/site-packages copr coloredlogs

# Runtime stage
FROM registry.access.redhat.com/hi/python:latest
COPY --from=builder /app/site-packages /app/site-packages
COPY ansible/roles/obs/files/copr_bridge.py /app/copr_bridge.py
ENV PYTHONPATH=/app/site-packages
ENTRYPOINT ["python3", "/app/copr_bridge.py"]
