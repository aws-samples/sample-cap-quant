-- litellm 库由 POSTGRES_DB 创建;langfuse 用同实例的独立库(仅本地;云上为 RDS 内独立库)
CREATE DATABASE langfuse;
GRANT ALL PRIVILEGES ON DATABASE langfuse TO tpp;
