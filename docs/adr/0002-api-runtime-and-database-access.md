# 0002. API runtime behaviour and database access

- Status: Accepted
- Date: 2026-10-24

## Context

TaskFlow runs as ECS tasks behind an ALB and talks to RDS PostgreSQL. Several behaviours sit on the
boundary between the application and the platform, and each has a failure mode that only shows up
in AWS: health checks, shutdown during deployments, schema migrations, database credentials and TLS.

## Decision

1. **`/health` is a liveness check only.** It returns `200` while the process can serve HTTP and
   does not query the database. The ALB target group and the ECS container health check both use it.
2. **Graceful shutdown.** ECS deregisters a task from the target group and waits out the
   deregistration delay before sending `SIGTERM`. On `SIGTERM` the app therefore closes the HTTP
   server immediately (finishing in-flight requests), then ends the database pool, then exits.
   There is no "flip to unhealthy and wait" step.
3. **Migrations run as a separate one-off ECS task** in the pipeline's deploy stage, before
   `update-service`, using the RDS master credentials. The deploy fails if the migration task exits
   non-zero. Migrations must stay backward-compatible because old and new tasks overlap during a
   rolling deployment.
4. **The application connects as a restricted role** (`taskflow_app`, CRUD on application tables
   only), created by the migrations. The app never receives the master credentials.
5. **TLS to RDS is on by default** and verifies the server certificate against the bundled RDS CA.
   Only local development disables it.
6. **Connection pool is bounded** (`DB_POOL_MAX`, connect timeout, statement timeout).
7. **Errors use RFC 9457** `application/problem+json` from one central error handler.

## Consequences

- A database outage leaves tasks running and returning `5xx` for data requests, instead of ECS
  restarting every task in a loop. `/health` cannot prove the database is reachable, so the
  pipeline's smoke test must also exercise a database-backed endpoint.
- Startup migrations under concurrency are avoided: `node-pg-migrate` takes a non-blocking advisory
  lock, so simultaneous task starts would fail rather than wait.
- A separate task definition is needed for migrations, because `run-task` overrides can change the
  command and environment but not secrets.
- The master secret, which RDS rotates on a schedule, is read only by the short-lived migration task.
- Connection budget: peak running tasks (including deployment overlap) × `DB_POOL_MAX` plus admin
  connections must stay below the instance's `max_connections`.
