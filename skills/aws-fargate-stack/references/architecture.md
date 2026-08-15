# Architecture — public-facing ECS Fargate app

## Topology

```
                        Internet
                            │
                    ┌───────▼────────┐
                    │  WAFv2 web ACL │  managed rule groups + rate limit + (optional) geo/IP match
                    └───────┬────────┘
                            │ associated with the ALB
            PUBLIC SUBNETS  │  (2+ AZs, IGW default route)
                    ┌───────▼────────────────────┐
                    │  internet-facing ALB :443  │  ACM cert, TLS 1.2+ policy, HTTP→HTTPS redirect
                    │  access logs → S3          │  deletion_protection = true
                    └───────┬────────────────────┘
                     path rules: /api/* → api tg · /* → frontend tg
                            │
            PRIVATE SUBNETS │  (2+ AZs, NAT egress, assign_public_ip = DISABLED)
        ┌───────────────────┼────────────────────────────┐
        ▼                   ▼                            ▼
  ECS svc frontend    ECS svc api                  ECS svc worker (optional)
  fixed 2             min 2 / max N                min 1 / max N
  frontend-task-role  api-task-role                worker-task-role
  no AWS perms        DB + its own secrets         DB + queue + its own secrets
        │                   │                            │
        └───────────────────┴────────────┬───────────────┘
                                         ▼
                        RDS PostgreSQL — private, IAM auth, encrypted
                        SG admits ONLY the task SGs
                                         │
                        (optional) SQS queue + DLQ for the worker
```

Everything the app needs that is not in the VPC (registry pulls, logs, queue, secrets) egresses through
**NAT**. Add **interface endpoints** only for flows that must not traverse the public internet — each
costs 1 ENI per subnet against the IP budget (see `discovery.md`).

## Why this shape

- **One ALB serving both tiers on one hostname** means the frontend's API base URL builds **relative**,
  so a single frontend image is valid in every environment. Splitting hostnames forces a rebuild per
  environment and re-introduces CORS.
- **Fargate, not EC2**: no AMI patching, no capacity provider tuning, no cluster autoscaler.
- **ARM64**: cheaper per vCPU-hour and the toolchain is mature. Build with `--platform linux/arm64`;
  build on an ARM runner if one exists, since cross-platform emulation is slow.
- **Worker has no load balancer and no inbound rules at all.** It reaches out; nothing reaches in.

## Resource inventory

Counts are indicative — a real root lands near 100–130 resources once SG rules and alarms are counted
individually.

| Group | Resources |
|---|---|
| Registry | ECR repo per image (`scanOnPush = true`, immutable tags) + lifecycle policy each |
| Cluster | 1 ECS cluster, Container Insights **on** (required for backlog-per-task scaling maths) |
| Task defs | api, frontend, worker, **migrate** (migrate uses the *api* image — see below) |
| Services | api, frontend, worker |
| Ingress | internet-facing ALB · HTTPS:443 listener · HTTP:80 redirect listener · 2 target groups · path rules |
| Edge security | WAFv2 web ACL + ALB association + logging configuration |
| DNS | A-alias in the **public** zone → ALB |
| Network security | 1 SG per service + ALB SG + RDS SG (+ endpoint SG if used), rules as **separate** resources |
| Database | RDS instance · subnet group · **parameter group** · managed master secret + rotation |
| Crypto | KMS CMK + alias (RDS storage, logs, secrets) |
| Queue | SQS queue + DLQ with redrive, if a worker exists |
| Identity | task role per service + one shared execution role + inline policies |
| Logs | one CloudWatch log group per service, explicit retention |
| Alarms | SNS topic + subscription + the alarm set below |
| Scaling | scalable target + policy per scalable service |
| CI | OIDC provider (if absent) + CI role(s) + policy |
| State | backend bucket with **versioning** + lock table |

### The migrate task definition uses the *api* image

Migrations ship with the api build, so the migration code can never drift from the ORM it migrates.
Its command overrides the entrypoint to run the migration tool. It needs its own task role — usually
the only role permitted to read the DB **master** secret, since it performs owner-level DDL.

## Naming

Interpolate everything from `${env}` and an app name; never hard-code an environment literal. That is
what makes adding prod a tfvars file rather than a rewrite.

```
${env}-${app}                     cluster, RDS, ALB, SNS topic, queue
${env}-${app}-${svc}              services, task definitions, log groups, SGs
${env}-${app}-${svc}-task-role    task roles
${env}/${app}-${svc}              ECR repositories
${env}-${abbrev}-${svc}           TARGET GROUPS — 32-char cap, abbreviate (traps.md #4)
```

## Alarm set

Fifteen or so, in three tiers. Each must have a plausible human response — an alarm nobody acts on
trains people to ignore the topic.

**Edge / availability**
- ALB target 5xx rate
- ALB 5xx (load-balancer generated, i.e. no healthy target)
- Unhealthy target count, per target group
- ALB rejected/surge queue depth (saturation)
- WAF blocked-request spike — both an attack signal *and* a false-positive signal after a rule change

**Application**
- Service running count below desired, per service
- Queue depth high and age-of-oldest-message high (worker fell behind)
- DLQ **not empty** — always alarm-worthy
- Task stopped with a non-zero exit / repeated restarts

**Database** (a small burstable class needs all four — see `traps.md` #19)
- CPU high
- `DatabaseConnections` approaching the configured `max_connections`
- `FreeableMemory` low
- `ReadLatency` high
- `CPUSurplusCreditsCharged > 0` on any `t3`/`t4g` class

Route them to one SNS topic; **confirm the email subscription** (`traps.md` #18).

## Autoscaling

- **frontend** — fixed count. It is stateless and cheap; scaling it adds moving parts for little gain.
- **api** — target tracking on `ECSServiceAverageCPUUtilization` (~60%). Cap the maximum at what the
  **database connection budget** allows, not at what CPU suggests (`database.md`).
- **worker** — target tracking on a CloudWatch **math metric**, *backlog per task* =
  `ApproximateNumberOfMessagesVisible / RunningTaskCount`, target ~10. Queue depth alone scales wrongly
  as task count changes. Requires Container Insights. **Floor of 1 if the worker owns scheduled work**
  (`traps.md` #16).

## Rollout

Rolling update with the **deployment circuit breaker and rollback enabled** — a failed rollout reverts
itself instead of leaving a half-updated service. `stopTimeout = 120` (Fargate's ceiling), and design
drain as checkpoint-and-exit (`traps.md` #15).

Deploy order is fixed: **migrate → assert exit 0 → update services**. Never in parallel.

## Deliberately not here

- **CloudFront / global edge.** Add it when you need caching, global latency, or Shield Advanced. It
  changes the certificate story (us-east-1) and moves WAF to the distribution.
- **Service discovery / service mesh.** Two services and a database do not need it.
- **EKS.** A control plane, an upgrade treadmill, and IRSA plumbing for three containers. Also: the VPC
  CNI allocates a VPC IP per pod, which small enterprise CIDRs cannot absorb.
- **RDS Proxy.** Worth it when connection count becomes the binding constraint; start with bounded
  pools and measure.
