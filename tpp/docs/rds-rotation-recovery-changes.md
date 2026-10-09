# RDS Password Rotation Auto-Recovery: File Change Notes

This document records the code and documentation changes made to add automatic recovery from RDS password rotation for LiteLLM and Langfuse.

## Background

The RDS managed master password rotates automatically every 7 days. Previously, even after External Secrets updated the Kubernetes Secret, already-running Pods
would not refresh their environment variables automatically, and LiteLLM and Langfuse kept using the old password.

The current recovery chain is:

```text
RDS / Secrets Manager password rotation
  → External Secrets refreshes the Kubernetes Secret within at most 5 minutes
  → Stakater Reloader detects the Secret data change
  → LiteLLM, Langfuse Web, and Langfuse Worker roll-restart
  → New Pods start with the new password
```

## Application Configuration Changes

### `apps/langfuse.tf`

- Changed the `refreshInterval` of the `langfuse-postgres` ExternalSecret from `1h` to `5m`.
- URL-encode the RDS password using `urlquery`.
- Generate `database_url` in the Secret:

  ```text
  postgresql://tpp:<url-encoded-password>@<rds-address>:5432/langfuse
  ```

- Added Reloader annotation resources for the Langfuse Web and Worker Deployments:

  ```text
  reloader.stakater.com/auto: "true"
  ```

### `apps/values/langfuse-values.yaml.tftpl`

- Injected into Langfuse Web and Worker:

  - `DATABASE_URL`
  - `DIRECT_URL`

- Both variables reference the `database_url` from the `langfuse-postgres` Secret.
- This avoids Prisma erroring when the RDS password contains reserved characters such as `@`, `:`, `/`, `%`, `#`, `?`:

  ```text
  P1013: invalid port number in database URL
  ```

### `apps/litellm.tf`

- Changed the `refreshInterval` of the `litellm-env` ExternalSecret from `1h` to `5m`.
- Added the Reloader annotation to the LiteLLM Deployment.
- Reserved and ignored the dynamic checksum environment variable written by Reloader, so that a subsequent `terraform apply` does not remove it and break the auto-reload behavior.

### `apps/platform.tf`

- Added the Stakater Reloader Helm release:

  ```text
  chart: reloader
  version: 2.2.16
  namespace: kube-system
  ```

- Reloader watches ConfigMap and Secret changes globally and only restarts workloads carrying the auto-reload annotation.

## Documentation Changes

### `README.md`

- Updated the `platform.tf` component description to include Reloader.
- Added an "RDS Credential Rotation and Auto-Recovery" section.
- Notes:

  - The RDS rotation period is still 7 days;
  - 5 minutes is the maximum polling interval for External Secrets to detect the new password;
  - Reloader automatically triggers rolling restarts of LiteLLM and Langfuse;
  - The Langfuse database URL must encode the password.

### `docs/architecture.md`

- Updated the `platform.tf` component description to include Reloader.
- Added an "RDS Credential Rotation and Auto-Recovery" architecture section.
- Documented the recovery chain across the RDS Secret, ESO, Reloader, and the three application workloads.
- Documented the encoding requirement for Langfuse `DATABASE_URL` / `DIRECT_URL`.

## Verification Results

- LiteLLM started successfully using the rotated RDS password.
- Langfuse Web and Worker connected to PostgreSQL successfully, with no pending Prisma migrations.
- Verified by injecting temporary, non-credential Secret data updates into `litellm-env` and `langfuse-postgres`:

  - Reloader detected the Secret data change;
  - LiteLLM automatically roll-restarted;
  - Langfuse Web and Worker automatically roll-restarted;
  - All three workloads returned to Ready.

- Subsequent External Secrets syncs removed the temporary Secret data used for testing.
