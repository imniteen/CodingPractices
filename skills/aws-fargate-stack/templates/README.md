# Templates — starting points, not drop-in files

These are **skeletons for the parts that are non-obvious and expensive to get wrong.** They are not a
complete Terraform root, and they have not been applied as written. Treat every one as a draft to adapt,
and always review a `terraform plan` before applying.

| File | Covers | Why it is here rather than left to memory |
|---|---|---|
| `alb-waf.tf` | Internet-facing ALB, listeners, target groups, WAFv2, public DNS | The whole public edge has no equivalent in an internal deployment, so it is the part most likely to be written from memory and got wrong. TLS policy, WAF *association* (vs creation), and count-before-block mode are each a real failure. |
| `ecs-service.tf` | Task definitions (api, worker, migrate), services, autoscaling | Contains `lifecycle { ignore_changes = [task_definition, desired_count] }` and the reasoning about what it makes impossible. Also the hardening block that must never be softened. |
| `gitlab-ci.yml` | Full pipeline: gate → test → build → tf → migrate → deploy → smoke | Encodes the `needs`/`rules` trap that can make a pipeline *uncreatable*, the migrate-gates-deploy ordering, and the build-arg requirement. |
| `DEPLOY_FACTS.md` | Phase 0 output; live-state and drift tracking | The three lists at the end — committed-not-applied, applied-not-verified, waiting-on-another-team — are the ones that rot silently. |

## What is deliberately not templated

Resources where the right answer depends entirely on the project, and a template would encourage
copying instead of thinking:

- **IAM task-role policies.** The whole point is least privilege for *your* services. See
  `references/security.md` for the shape and the negative tests, then write them.
- **RDS.** The class, `max_connections`, and pool sizes all follow from the connection-budget
  arithmetic in `references/database.md`. A copied instance block hides that maths.
- **Security groups and their rules.** Per-service, and the rules must be separate resources to avoid
  dependency cycles (`traps.md` #5).
- **Alarms.** The list is in `references/architecture.md`; thresholds are yours. An alarm nobody acts on
  trains people to ignore the topic.

## Before using any of these

1. Complete phase 0 and fill in `DEPLOY_FACTS.md`. The IP-budget gate can invalidate the whole design.
2. Read `references/traps.md`.
3. Replace every `<placeholder>`, `var.*` you have not defined, and `local.*` you have not declared.
4. `terraform validate`, then `plan`, then read the **whole** plan before applying.
