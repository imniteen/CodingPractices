---
name: aws-fargate-stack
description: Stand up a production-grade AWS deployment for a containerised web app — frontend + backend + PostgreSQL, with an optional background worker — on ECS Fargate behind a public ALB, using Terraform and GitLab CI. Use when deploying a new app to AWS, adding ECS Fargate infrastructure, wiring an ALB/WAF/RDS/ECR/autoscaling stack, building the CI pipeline that ships it, or reviewing such a deployment for production readiness. Asks for the target AWS account, region and sizing at runtime — nothing is hard-coded to one account or environment.
---

# AWS Fargate stack — public-facing containerised app

Deploys **frontend + backend + PostgreSQL (+ optional worker)** to **ECS Fargate (ARM64)** behind an
**internet-facing ALB with WAF**, provisioned by **one Terraform root** and shipped by **GitLab CI**.

This skill is a distilled, portable version of a deployment that was actually built and applied. Its
value is not the resource list — that is the easy part — it is the **failure modes in
`references/traps.md`**, every one of which was paid for in a real incident. Read that file before
writing Terraform, not after something breaks.

## Never skip these

Nothing below is a preference. A public-facing app has no network perimeter to hide behind, so these
replace the "internal-only" control an internal app would rely on:

1. **The database is never publicly reachable.** Private subnets, `publicly_accessible = false`, and a
   security group that admits *only* the task security groups — never a CIDR, never `0.0.0.0/0`.
2. **Tasks never get public IPs.** `assign_public_ip = DISABLED`, private subnets, egress via NAT.
   The ALB is the only thing in a public subnet.
3. **WAF is attached before the ALB serves real traffic.** Managed rule groups *and* a rate limit —
   a rate limit alone is not protection.
4. **Auth is enforced before the app trusts a request**, and authorization is resolved from your own
   datastore, never from a claim the client can influence.
5. **One task role and one security group per service.** Prove least privilege with a *negative*
   test: assert the frontend role cannot reach the database, that the api role lacks whatever the
   worker alone needs.
6. **Env carries secret PATHS, never values.** SSM/Secrets Manager fetched at runtime, granted by
   **exact ARN** — never a path wildcard.
7. **`enable_execute_command = false`**, `readonlyRootFilesystem = true`, non-root user, no privileged
   mode. ECS Exec is an interactive shell into a task holding your credentials.
8. **Migrations gate the deploy.** Run them as a one-off task, assert exit 0, *then* update services.
   `/readyz` must assert the schema is at head or targets go healthy before they can serve.
9. **Terraform state has locking and bucket versioning before CI is allowed to apply.** Without both,
   one racing pipeline corrupts state with no recovery path.

## Ask the operator first — do not assume

This skill is account-agnostic by design. Before any Terraform, ask (and record the answers in the
project so they are not re-litigated):

| Ask | Why it changes the work |
|---|---|
| **AWS account + region** | Determines every identifier. Nothing here is pre-filled. |
| **Environment posture** | Recommend **nonprod first, prod additive** — keep `env` a variable and interpolate every name, so adding prod is a tfvars file plus two CI jobs. Do not build prod sizing before the shape is proven. |
| **DB sizing + HA** | Single-AZ small class is fine for nonprod; prod needs Multi-AZ and a re-derived connection budget. See `references/database.md`. |
| **Worker now or later?** | If the worker owns any scheduled/sweeper duty, its floor is **1, never 0**, and it needs a drain contract. Design the seam now even if the service ships later. |
| **Hostname + certificate** | Public ACM cert must be in the **ALB's region**; DNS validation records must be creatable in the zone you actually control. |
| **Who may reach it** | "Public" rarely means "everyone" — ask whether it needs geo restriction, an IP allowlist, or authenticated-only access. |

If the operator is unsure on ingress, **default to the more private option**. You can always add public
exposure later; you cannot un-leak data.

## Phase order

Follow this sequence. It is ordered by *risk retired per step*, and each gate exists because skipping
it cost real time somewhere.

| Phase | Work | Gate |
|---|---|---|
| **0** | Discovery sweep of the target account — read-only | Facts table written; **IP budget passes** |
| **1** | Out-of-band bootstrap: state backend + locking, secrets, CI OIDC role | State locks; secrets exist |
| **2** | Terraform: network data sources, SGs, KMS, RDS, endpoints | `plan` clean |
| **3** | ECR + task/exec roles | `plan` clean |
| **4** | ECS cluster, task defs, services, public ALB + WAF, DNS, autoscaling | Services steady; WAF attached |
| **5** | Alarms, SNS, log groups | Alarms visible; **SNS subscription confirmed** |
| **6** | App code deltas (DB auth, `/readyz`, drain, build-time config) | Unit suite green |
| **7** | CI pipeline | Pipeline green end to end |
| **8** | Canary: real request through the public edge → persisted → visible | Acceptance in `references/verification.md` |

**Phase 0 is not optional and its output is not prose.** Write a facts table into the project
(`DEPLOY_FACTS.md` or a spec appendix) recording every identifier with the date it was verified. Six
weeks later nobody remembers whether a subnet id was checked or assumed, and a wrong one produces a
plan that applies cleanly and fails at runtime.

## Reference files

Load what the current phase needs; do not read them all up front.

| File | Read when |
|---|---|
| `references/traps.md` | **Before writing any Terraform.** The 25 failure modes. Highest value here. |
| `references/discovery.md` | Phase 0 — the sweep commands and the IP-budget gate |
| `references/architecture.md` | Phase 2–4 — topology, resource inventory, naming |
| `references/terraform.md` | Phase 2–4 — root layout, tfvars, state, apply discipline |
| `references/database.md` | Phase 2 + 6 — RDS, IAM auth, pool math, migrations |
| `references/security.md` | Phase 3–4 — task roles, WAF, edge auth, hardening |
| `references/pipeline.md` | Phase 7 — images, ECR, GitLab CI, and the `needs`/`rules` trap |
| `references/verification.md` | Phase 8 — acceptance criteria and how to *prove* each one |

`templates/` holds skeletons for the parts that are non-obvious and expensive to get wrong. They are
**starting points requiring a plan review**, not drop-in files.

## How to work

- **Read-only first.** Every phase begins by observing the account. Never infer deployed state from
  committed source — they diverge, and the divergence is usually the bug (`traps.md` #10).
- **Plan file, then apply that file.** `terraform plan -out=tfplan` then `terraform apply tfplan`.
  Never `-auto-approve` on a shared account. Read the whole plan: a two-resource change that reports
  "8 to add, 4 to destroy" is telling you something.
- **Confirm before every write to AWS**, and re-confirm for a *different* write later. Approval for
  one apply is not standing approval.
- **Record what you did.** Keep a running status document with what is applied, what is committed but
  *not* applied, and what is waiting on another team. "Fixed in code" and "fixed in the account" are
  different states, and conflating them is the single most common way this goes wrong.
