# PostgreSQL on RDS — IAM auth, connection budget, migrations

## The shape

- **Private only.** `publicly_accessible = false`, private subnets, and a security group that admits
  only the task security groups. Never a CIDR.
- **Encrypted at rest** with a customer-managed KMS key; TLS in transit, enforced by the client.
- **IAM database authentication for the application**, so the app holds **no password anywhere**.
- **RDS-managed master secret** (`manage_master_user_password = true`) with rotation, used *only* by
  migrations for owner-level DDL.
- **Backups + PITR.** Retention is a decision to state, not a default to inherit.
- **`deletion_protection = true`** once you stop iterating. Know the consequence: `terraform destroy`
  will fail on the DB until someone deliberately flips it back. That is the feature.

## Two identities, deliberately

| Identity | Auth | Used by | Grants |
|---|---|---|---|
| app user | IAM token (15 min TTL) | api, worker | DML + read on the app schema; **no DDL** |
| master | managed secret | migrate task only | owner DDL |

The app cannot alter its own schema, and the migration credential is not sitting in a long-running
service. The migrate task role is typically the only one permitted `secretsmanager:GetSecretValue` on
the master secret.

Bootstrap the app user once, as master, in your first migration or a documented bootstrap step:

```sql
CREATE USER app_user;
GRANT rds_iam TO app_user;            -- this is what enables IAM token auth
GRANT CONNECT ON DATABASE app TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
```

The `ALTER DEFAULT PRIVILEGES` line is the one people forget — without it, every *future* table is
invisible to the app and the failure appears long after the grant "worked".

## IAM auth has three client requirements

Tokens expire in **15 minutes**, which breaks the usual long-lived-pool assumption:

1. **Mint a token per connection**, in a connect hook — not once at startup.
2. **`pool_recycle` well under 900 s** so no connection outlives its token.
3. **`pool_pre_ping = True`** so a dead connection is detected and replaced rather than surfacing as a
   query error.

Also require SSL. The IAM grant authenticates you; it does not encrypt you.

The task role needs `rds-db:connect` on the *DB user* resource ARN, which embeds the **DbiResourceId**
(not the instance identifier):

```
arn:aws:rds-db:<region>:<account>:dbuser:<DbiResourceId>/<db_user>
```

Read the resource id from the instance — and note it **changes if the instance is recreated**, which
silently breaks auth after a restore. Wire it from a Terraform reference, never paste it.

## The connection budget decides autoscaling maxima

This is a constraint people discover in production. Work it out explicitly:

```
worst case backends = (api_max × (api_pool + api_overflow))
                    + (worker_max × (worker_pool + worker_overflow))
                    + migration task
                    + your own admin sessions
```

That total must sit **comfortably** under the instance's `max_connections`. On small burstable classes
the effective ceiling is low — a `db.t3.micro` lands near 112 by RDS's default formula, and the default
formula is memory-derived, so it drops as you shrink.

Two implications:

- **Bound the pools explicitly** (e.g. api `pool_size=3, max_overflow=2`; worker `pool_size=2,
  max_overflow=1`). Framework defaults are far too generous for Fargate, where every task is another
  full pool.
- **Cap autoscaling maxima on the connection budget, not on CPU.** A service that scales to 10 tasks
  and exhausts connections is *less* available than one capped at 4.

Set `max_connections` explicitly in a parameter group rather than inheriting the formula, so the DB
**refuses** connections predictably instead of thrashing.

## Parameter group

Set these deliberately:

- `max_connections` — explicit, matching the budget above
- `work_mem` — the default × concurrent sorts is a common OOM path on small classes; lower it
- `pg_stat_statements` — enabled, or you have no query-level evidence when things slow down
- `log_min_duration_statement` — a slow-query threshold you will actually read

## Storage

**gp3, not gp2.** At small volumes gp2 grants IOPS proportional to size (~3/GB, so ~100 at 20 GB) with
burst credits that deplete; gp3 gives 3000 IOPS / 125 MB/s baseline at any size for similar money.

A memory-starved instance reads from disk **more**, so IOPS matter more on a small class, not less. This
is the single highest-leverage line in the RDS config. Enable storage autoscaling with a max.

## Migrations gate the deploy

Order is fixed and not negotiable:

1. Register a task-definition revision of the **migrate** family with the new image
2. `run-task`, wait for it to stop, assert **exit code 0**
3. Only then `update-service` on the app services

Two details that matter:

- **Derive the migration task's network config from the api service** rather than duplicating subnet and
  SG ids as CI variables. The migration must run in exactly the subnets and SG that Terraform granted
  RDS ingress to, and reading it from the service means the two cannot drift:

  ```bash
  aws ecs describe-services --cluster "$C" --services "$C-api" \
    --query 'services[0].networkConfiguration.awsvpcConfiguration' --output json
  ```

- **`/readyz` must assert the schema is at head.** Without it, targets pass health checks before the
  schema exists, and a rollout that is merely *out of order* looks like a deploy failure.

A failed migration must stop the pipeline before any service is touched.

## Idempotency and replay

Anything triggered by an at-least-once source (a queue, a webhook, a retried request) **will** be
delivered twice. Make the write idempotent with a unique constraint on a natural key, and handle the
conflict path deliberately.

A real failure worth internalising: a redelivered message hit a `UNIQUE` violation on a derived
identifier, the transaction aborted, the message returned to the queue, and it poisoned the queue in a
loop. Handle the duplicate as an expected outcome — return the existing row — rather than letting the
constraint surface as an error.

## Nonprod vs prod

| Nonprod | Prod must revisit |
|---|---|
| single-AZ small class | **Multi-AZ**, a class with real headroom, connection budget re-derived |
| `deletion_protection = false` while iterating | `true` |
| autoscaling maxima capped by a tiny connection budget | raise once the DB is sized; consider RDS Proxy |
| failover never exercised | **run a failover drill before prod cutover** — specifically that IAM tokens re-mint and pools recover |

That last row is the one that bites. Multi-AZ failover plus 15-minute IAM tokens plus a connection pool
is exactly the combination that behaves differently under failure than in steady state. Temporarily
enable Multi-AZ in nonprod and force a failover before you rely on it.
