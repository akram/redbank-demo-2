FROM registry.access.redhat.com/ubi9/python-312:latest

WORKDIR /opt/app-root
COPY requirements.txt .
RUN python3 -m pip install --upgrade pip setuptools wheel && \
    python3 -m pip install --no-cache-dir -r requirements.txt

COPY knowledge_agent/ knowledge_agent/

ENV PYTHONUNBUFFERED=1

EXPOSE 8002
CMD ["python3", "-m", "knowledge_agent"]
