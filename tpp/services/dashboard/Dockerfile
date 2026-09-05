FROM python:3.12-slim

WORKDIR /app
COPY pyproject.toml ./
COPY dashboard ./dashboard
RUN pip install --no-cache-dir .

USER 65534
EXPOSE 8080
CMD ["dashboard"]
