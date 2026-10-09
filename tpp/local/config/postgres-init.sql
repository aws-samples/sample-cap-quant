-- The litellm database is created via POSTGRES_DB; langfuse uses a separate database on the same instance (local only; in the cloud it is a separate database within RDS)
CREATE DATABASE langfuse;
GRANT ALL PRIVILEGES ON DATABASE langfuse TO tpp;
