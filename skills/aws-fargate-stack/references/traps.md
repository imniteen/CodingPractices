# Traps — failure modes paid for in real incidents

Each entry is a defect that shipped, or nearly shipped, on a real deployment. The pattern is almost
always the same: **something succeeded that should have failed, or two sources of truth disagreed and
the wrong one was believed.**

Read this before writing Terraform.

---

## A. Terraform ↔ ECS interaction (the most expensive category)

### 1. `terraform apply` cannot move a running ECS service

ECS services must carry:

```hcl
lifecycle {
  ignore_changes = [task_definition, desired_count]
}
```

…because CI registers new task-definition revisions and calls `update-service`, and autoscaling owns
the count. **Consequence people miss:** once that block exists, `apply` will happily register a new
task-definition revision that *no service ever adopts*. Terraform reports success. The running task
definition is unchanged. A drifted revision then sits in the account looking authoritative.

This silently broke every SSH diagnosis on one deployment: the task definition in state had the right
SSH user, the *running* revision had a stale one, and `apply` could not fix it because of this very
block. **Always verify the deployed revision, not the one Terraform just wrote.**

### 2. The `image_tag` placeholder default creates revisions pointing at images that do not exist

If `variable "image_tag"` has a placeholder default (`bootstrap`, `latest`, `dev`), any apply that
omits `-var image_tag=...` bakes that placeholder into four task-definition families. One deployment
had state referencing tag `bc5451a3` — a tag present in **no** ECR repository, written by a CI job that
applied before the image was built. Nothing broke *only* because trap #1's `ignore_changes` meant the
services never followed.

**Rule: every apply passes `-var image_tag=<the tag actually running>`.** Read it from the live service
first:

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$CLUSTER-api" \
  --query 'services[0].taskDefinition' --output text
# then describe-task-definition and read containerDefinitions[0].image
```

The residue is worse than it looks: the bogus revision becomes the *latest* in its family, so any
`run-task --task-definition <family>` (no revision) picks a nonexistent image.

### 3. CI overrides the image, so CI is not the thing that protects you

A pipeline helper that does `describe-task-definition | jq '.containerDefinitions[0].image = $IMG'`
always overrides the tag, so **CI is safe from #2 while local applies are not.** Do not conclude from
"CI works" that local applies are fine.

### 4. Target group names cap at 32 characters

`aws_lb_target_group.name` is limited to 32 chars. A perfectly reasonable
`<env>-<app>-frontend` becomes 33 and the apply fails late, after other resources exist. Abbreviate
target groups deliberately and note the abbreviation, or use `name_prefix`.

### 5. Security-group rules must be separate resources

Use `aws_vpc_security_group_ingress_rule` / `_egress_rule`, not inline `ingress`/`egress` blocks.
Inline blocks create dependency **cycles** the moment two SGs reference each other (ALB↔api,
frontend↔api). Also: Terraform-created security groups have **no implicit allow-all egress** — the
AWS console default misleads here. State DNS-to-VPC-resolver egress explicitly or resolution fails
with no obvious cause.

### 6. An org sweeper may tag your load balancer for deletion

Cloud-governance tooling (Cloud Custodian and similar) tags idle ELBs `Unused-ELB` with a
`delete@<date>` deadline. Two consequences: the LB is on a deletion clock until it has healthy targets
and real traffic, and the out-of-band tags cause drift on every plan. Add
`lifecycle { ignore_changes = [tags["..."], tags_all["..."]] }` for those specific keys so the sweeper
can manage them without fighting Terraform — and re-check the tags before assuming the deadline is
still live.

---

## B. State and CI permissions

### 7. State locking and bucket versioning must exist before CI can apply

An S3 backend with no lock (DynamoDB table or S3 native locking) and no bucket versioning is harmless
while one human applies serially. The moment a pipeline can apply, a race corrupts state — and with no
versioning there is no history to recover from. **Do this in phase 1, not after CI is wired.**

### 8. An IAM deny that blocks `plan` cannot be fixed by CI — this deadlocks

A policy that denies `iam:*` on the CI roles themselves also denies `iam:GetRole`. Terraform must
**refresh** roles it holds in state, so `plan` dies before producing anything. The apply job needs the
plan artifact, so `apply` can never run either. **The pipeline cannot repair itself** — it takes one
human apply with elevated credentials.

The fix pattern, which keeps writes denied while permitting the reads `plan` requires:

```hcl
statement {                       # Allow the reads plan needs
  sid       = "ReadCIRolesSoPlanCanRefresh"
  effect    = "Allow"
  actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies",
               "iam:ListAttachedRolePolicies", "iam:ListRoleTags",
               "iam:ListInstanceProfilesForRole"]
  resources = ["arn:aws:iam::${account}:role/CI-ROLE-PREFIX-*"]
}
statement {                       # Deny everything else — NotAction, so it is fail-closed
  sid        = "DenyEverythingButReadsOnCIRoles"
  effect     = "Deny"
  not_actions = [ ...the same six... ]
  resources  = ["arn:aws:iam::${account}:role/CI-ROLE-PREFIX-*"]
}
```

`NotAction` rather than a list of mutating verbs, so IAM write actions AWS ships *next year* are denied
too. Verify with `aws iam simulate-principal-policy` — reads `allowed`, `UpdateAssumeRolePolicy` /
`AttachRolePolicy` / `DeleteRole` `explicitDeny`. (Some org SCPs deny `SimulatePrincipalPolicy`; check.)

**Standing consequence to document:** CI can now *plan* those roles but never *change* them, so every
future edit to the CI roles needs a human apply. Nothing in the pipeline will tell you — it just fails
on the role it may not touch.

### 9. CI is a privilege-escalation path

`iam:PassRole` on a task role plus `RegisterTaskDefinition` equals arbitrary code running **as** that
role. Scope `PassRole` to exact task-role ARNs, require protected branches, and block fork-MR
pipelines **before** granting the deploy role anything.

---

## C. GitLab CI structure

### 10. A job with no `rules` is absent from merge-request pipelines, and a `needs` on it breaks the whole pipeline

This one is vicious. A job with no `rules`/`only`/`except` falls back to GitLab's default
`only: [branches, tags]` — **excluded from MR pipelines.** A job that *does* declare `rules` is
included. So:

```yaml
deploy:                  # no rules -> absent from MR pipelines
  stage: deploy
smoke:
  needs: [deploy]        # present in MR pipelines -> references a job that does not exist
  rules: [- when: on_success]
```

The MR pipeline is **refused at creation** — "0 jobs", `yaml invalid`. Not "smoke is skipped": *nothing
runs*, including the security/test gates that were supposed to be unskippable. A structural CI mistake
silently disabled the safety gate.

Fix both halves:

```yaml
needs:
  - job: deploy
    optional: true       # structural guard; only relaxes when the job is absent entirely
rules:
  - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    when: never          # behavioural: smoke asserts LIVE state, meaningless on an unmerged branch
  - when: on_success
```

`optional: true` does not weaken the gate — wherever the job exists, `needs` still waits for it and
still inherits its skipped/failed state.

### 11. Jobs with `changes:` rules run in MR pipelines from unmerged refs

Build jobs gated on `changes:` **do** appear in MR pipelines. Even `when: manual`, one click pushes an
image to your registry from an unmerged branch using the deploy role. Audit which jobs can touch AWS
from an MR before enabling protected branches, not after.

### 12. A lint or test gate you never ran locally will fail the first pipeline

One project's `ruff check packages/` gate had 83 findings — the very first pipeline would have failed
at `test`, before build or deploy. Run every CI gate locally before pushing the pipeline that enforces
it.

---

## D. Application and container

### 13. Build-time frontend config must be a Docker build ARG

Next.js `NEXT_PUBLIC_*` (and every equivalent bundler inline) is baked in at **build** time. Passing it
as a runtime environment variable leaves the browser fetching a relative path — a 404 that looks like a
routing bug. It must be a `Dockerfile` `ARG` plus `build.args` in compose/CI.

Corollary worth designing for: if the api and UI share one hostname, the base URL builds **empty and
relative**, and *one* frontend image is valid in every environment. A per-environment hostname forces a
rebuild per environment.

### 14. `/readyz` must assert migrations are at head

Otherwise targets pass health checks and start serving before the schema exists. This is also *why*
migrations gate the deploy — if services update first, targets stay unhealthy and the rollout looks
like a deploy failure rather than an ordering mistake.

### 15. Fargate `stopTimeout` caps at 120 s

If your unit of work can exceed that, "drain" cannot mean "finish in flight". It must be **stop
accepting → checkpoint → exit**, relying on queue redelivery. Set the queue visibility timeout to
several times the processing budget so redelivery is not premature.

### 16. A worker that owns scheduled work must never scale to zero

If the worker runs an in-process sweeper (closing windows, expiring records, rollups), its floor is
**1**, not 0 — otherwise the scheduled work simply stops with no error anywhere. Two concurrent
sweepers must therefore be safe by construction: `SELECT ... FOR UPDATE SKIP LOCKED` plus advisory
locks.

### 17. Non-load-balanced services use a container `healthCheck`, not a health server

Do not add an HTTP server to a worker just to satisfy a health check. ECS supports a container-level
`healthCheck` command for services with no target group.

---

## E. Observability

### 18. An SNS email subscription requires a human click

Terraform creates the subscription; AWS emails a confirmation link. Until someone clicks it the
subscription sits in `PendingConfirmation` and **every alarm delivers to nobody**. Unconfirmed
subscriptions are deleted after roughly three days.

Worse failure mode observed: a status document recorded this as "done — awaiting the click" when the
subscription did not exist in AWS *or* in state at all. Verify with
`aws sns list-subscriptions-by-topic`, not from a document.

### 19. Alarms on a burstable DB class need a credit alarm

`db.t3`/`db.t4g` default to **unlimited** mode, so sustained burst *bills* rather than throttles. Alarm
on `CPUSurplusCreditsCharged > 0` or the first symptom is an invoice. Also alarm `FreeableMemory` low
and `ReadLatency` high — on a small class these fire before CPU does.

---

## F. Operational discipline

### 20. Verify deployed state, not committed source

The most repeated lesson. Committed tfvars said the SSH user was one thing; the *running* task
definition said another, and the running config was the truth. Whenever behaviour contradicts the
repository, believe the account.

### 21. "Fixed in code" and "fixed in the account" are different states

Track them separately and explicitly. One project carried a correct, committed, reviewed IAM fix for
two days while CI failed on the exact problem it fixed — because nobody had applied it. Every status
document should have a column for *applied?*, not just *merged?*.

### 22. `aws --output text` sorts keys alphabetically, not in query order

`--query 'x.[running,desired,pending]' --output text` does **not** return them in that order. This
nearly produced a report of `running=0/desired=1/pending=2` from healthy services. Use
`--output json` whenever reading more than one field.

### 23. Read the whole plan, and diff the noise from the substance

A plan for a two-resource change reporting "7 to add, 1 to change, 4 to destroy" is telling you the
account has drifted. Provider null-vs-empty normalisation (`ipc_mode`, `portMappings`,
`systemControls`) produces churn that looks alarming and means nothing — extract the real diff:

```bash
terraform show -json tfplan | python3 -c '...'   # compare before/after per attribute
```

Never approve a destroy you have not explained to yourself.

### 24. Immutable registry tags cannot be reclaimed

With ECR immutability on, a bad image tag is permanent — you cannot re-push the same tag with fixed
content. Record which tags must never be deployed and let the lifecycle policy age them out.

### 25. Sessions expire mid-operation

SSO credentials expire (commonly 12 h) and will fail *between* two commands in a sequence, leaving
partial work. For any multi-step write, refresh first and re-verify the end state afterwards rather
than trusting that step 3 of 5 succeeded.

---

## Interpreting this list

The unifying lesson: **two sources of truth will disagree, and the failure is believing the convenient
one.** Committed source vs deployed state. A status document vs the API. Terraform's success message vs
the running revision. When they conflict, query the account.
