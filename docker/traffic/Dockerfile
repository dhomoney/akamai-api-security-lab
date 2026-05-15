FROM python:3.12-slim
WORKDIR /app
COPY scripts/traffic/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY scripts/traffic/locustfile.py scripts/traffic/attackfile.py ./
ENTRYPOINT ["python", "-m", "locust"]
CMD ["--help"]
