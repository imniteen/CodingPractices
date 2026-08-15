# DEPLOY_FACTS — verified environment facts

> **TEMPLATE.** Copy into the project at the start of phase 0 and fill it from the read-only sweep in
> `references/discovery.md`. Every row records the date it was **verified**, because six weeks later
> nobody remembers whether a subnet id was checked or assumed — and a wrong one produces a plan that
> applies cleanly and fails at runtime.
>
> Rule: if a row is not verified, write `ASSUMED` in it. Never leave it blank and never guess.

## Target

| Fact | Value | Verified |
|---|---|---|
| AWS account (number, not alias) | | |
| Region | | |
| Access role / profile | | |
| Permission boundary? | | |
| SCP denials observed | | |

## Network

| Fact | Value | Verified |
|---|---|---|
| VPC id / CIDR | | |
| VPC owner / IaC-managed by | | |
| **Public** subnets (ALB) — id, AZ, free IPs | | |
| **Private** subnets (tasks, RDS) — id, AZ, free IPs | | |
| Subnets deliberately EXCLUDED, and why | | |
| IGW / default route confirmed on public subnets | | |
| NAT gateways + egress IPs | | |
| Existing VPC endpoints | | |

## IP budget — the gate

| Tier | Demand | Available | Utilisation |
|---|---|---|---|
| Public (ALB, 8–16 per AZ) | | | |
| Private (tasks at max + migrate + RDS + endpoint ENIs) | | | |

```
private demand = tasks_at_max + 1 + rds_enis + (interface_endpoints × subnets)
```

**Verdict: PASS / FAIL** — >70% utilisation is a FAIL; choose another VPC or account.
Show the arithmetic, not just the answer.

## Ingress

| Fact | Value | Verified |
|---|---|---|
| Hostname | | |
| ACM certificate ARN (must be in the ALB's region) | | |
| Certificate covers the hostname? Status ISSUED? | | |
| **Public** hosted zone id | | |
| Private zone of the same name exists? (split-horizon) | | |
| Conflicting wildcard record to beat? | | |
| Access restriction: everyone / geo / IP allowlist / authenticated-only | | |

## Data and state

| Fact | Value | Verified |
|---|---|---|
| DB engine + version | | |
| Instance class · Multi-AZ · storage type (**gp3**) | | |
| `max_connections` set explicitly to | | |
| Connection budget arithmetic | | |
| Terraform state bucket + key | | |
| State bucket **versioning enabled?** | | |
| State **locking configured?** | | |

Both state rows must be `yes` before CI is allowed to apply.

## Identity

| Fact | Value | Verified |
|---|---|---|
| CI OIDC provider already registered? | | |
| CI terraform role ARN | | |
| CI deploy role ARN | | |
| Trust policy pins project path to | | |
| `iam:PassRole` scoped to (exact ARNs) | | |

## Precedent in this account

| Fact | Value | Verified |
|---|---|---|
| Existing ECS clusters | | |
| Existing RDS instances | | |
| Existing internet-facing LBs (there should be exactly one of yours) | | |
| Security Hub / Config / Inspector present? | | |

Absence of precedent is not a blocker, but it raises the value of a throwaway apply (phase 0b) before
committing to 100+ resources.

## Live state — what is actually deployed

Keep this current. It is the answer to "what is running?", and the place drift becomes visible.

| Service | Task def revision | Image tag | Running / desired | Checked |
|---|---|---|---|---|
| api | | | | |
| frontend | | | | |
| worker | | | | |

| Family | Latest revision | Image tag | Tag exists in registry? |
|---|---|---|---|
| api | | | |
| frontend | | | |
| worker | | | |
| migrate | | | |

The second table is the direct test for the placeholder-tag trap. A latest revision pointing at a tag
that is not in the registry is a latent outage for anything using `run-task --task-definition <family>`.

## The three lists that rot silently

Maintain these separately. Conflating them is the most common way a deployment goes wrong.

### Committed but NOT applied
<!-- commit SHA + what it changes + why it has not been applied -->

### Applied but NOT verified
<!-- what was applied + which acceptance check is still outstanding -->

### Waiting on another team
<!-- the ask, who owns it, when it was raised, what it blocks -->

## Outstanding manual steps

- [ ] SNS email subscription **confirmed** (not merely created — `PendingConfirmation` means alarms
      reach nobody, and it is deleted after ~3 days)
- [ ] WAF flipped from `count` to `block` after an observation period
- [ ] Protected branches enabled; fork-MR pipelines blocked
- [ ] Terraform state locking + bucket versioning
- [ ] Every CI gate run locally at least once
