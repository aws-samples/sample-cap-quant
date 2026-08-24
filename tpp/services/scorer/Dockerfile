FROM python:3.12-slim

WORKDIR /app
COPY pyproject.toml ./
COPY scorer ./scorer
RUN pip install --no-cache-dir .

USER 65534
EXPOSE 9100
CMD ["scorer"]
