# Terraform — layout, state, and apply discipline

## One root, flat files, no premature modules

A single Terraform root with files split by concern. Resist wrapping this in modules until a *second*
consumer exists — a module written for one caller encodes that caller's assumptions as an interface, and
you pay to unpick them later.

```
terraform/
  providers.tf              provider + required_versions
  remote_backend.tf         S3 backend (see below)
  variables.tf              every input, with descriptions that say WHY
  locals.tf                 name_prefix, derived SSM paths, computed ARNs
  data.tf                   VPC/subnet/cert/zone lookups by EXPLICIT id
  kms.tf
  sg.tf                     SGs + separate rule resources (traps.md #5)
  rds.tf                    instance, subnet group, parameter group, secret rotation
  sqs.tf                    queue + DLQ (if a worker exists)
  ecr.tf
  iam_task_roles.tf         one role + inline policy per service
  iam_ci_oidc.tf            CI role(s) — read traps.md #8 before touching
  ecs_cluster.tf
  ecs_task_definitions.tf
  ecs_services.tf           lifecycle.ignore_changes — traps.md #1
  alb.tf                    ALB, listeners, target groups, rules
  waf.tf
  dns.tf
  autoscaling.tf
  alarms.tf
  outputs.tf
  dc/<env>/<name>.tfvars    per-environment values
```

## Naming: interpolate, never literal

```hcl
locals {
  name_prefix = "${var.env}-${var.application_name}"
}
```

One hard-coded `"nonprod"` anywhere is the thing that turns "add prod" into a refactor. Grep for the
literal before declaring an environment portable.

Target groups need a shorter prefix because of the 32-character cap (`traps.md` #4). Choose the
abbreviation once, in `locals.tf`, with a comment explaining why it differs.

## tfvars carry decisions, and should say why

The tfvars file is where the next person looks to understand what was chosen. Comment the *reasoning*,
not the syntax — especially anything that looks wrong at a glance:

```hcl
# gp3, NOT gp2. At 20 GB, gp2 grants ~100 baseline IOPS with depleting burst credits; gp3 gives
# 3000/125 MB/s at any size. A memory-starved instance reads from disk MORE, so IOPS matter more.
db_storage_type = "gp3"

# false so DB parameter changes land in the maintenance window instead of restarting mid-day.
db_apply_immediately = false

# Consequence before a teardown: with deletion_protection on, `terraform destroy` FAILS on the DB
# until this is flipped back. That is the point — it should take a deliberate edit.
db_deletion_protection = true
```

Also record identifiers whose *provenance* matters: "verified by read-only sweep on `<date>`", or
"excluded deliberately — only 4 free addresses".

## State backend — versioning and locking are phase 1, not later

```hcl
terraform {
  backend "s3" {
    bucket       = "<state-bucket>"
    key          = "<env>-<app>/<dc>/terraform.tfstate"
    region       = "<region>"
    encrypt      = true
    use_lockfile = true     # S3 native locking (TF >= 1.10); or dynamodb_table on older versions
  }
}
```

Both are required before CI may apply (`traps.md` #7). Verify, do not assume:

```bash
aws s3api get-bucket-versioning --bucket "$STATE_BUCKET"     # expect Status: Enabled
```

If the bucket is shared and owned by another team, versioning may not be yours to enable — find that out
in phase 1, not the day a pipeline corrupts state.

## Apply discipline

**Plan to a file, apply that file.** Never `-auto-approve` against a shared account.

```bash
terraform plan  -var-file="dc/$ENV/$TFVARS" -var "image_tag=$RUNNING_TAG" -out=tfplan
terraform apply tfplan
```

Rules that follow from `traps.md`:

- **Always pass `image_tag` explicitly**, set to the tag *currently running* unless you intend a change
  (#2). Read it from the live service, not from a document.
- **Read the entire plan.** Reconcile the summary count against your intended change. If you meant to
  add two resources and it says "7 to add, 4 to destroy", stop and account for every line.
- **Extract signal from provider noise.** `ipc_mode`, `pid_mode`, `portMappings`, `systemControls`,
  `volumesFrom` churn is null-vs-empty normalisation. Diff the JSON plan per attribute rather than
  eyeballing coloured output:

  ```bash
  terraform show -json tfplan | python3 -c "
  import json,sys
  d=json.load(sys.stdin)
  for rc in d.get('resource_changes',[]):
      a=rc['change']['actions']
      if a!=['no-op']: print(f\"{'/'.join(a):16} {rc['address']}\")
  "
  ```
- **A saved plan is tied to its configuration and lock file.** Re-plan after any change, and note that
  `terraform apply <planfile>` must run from the directory holding `.terraform.lock.hcl` — running it
  from a parent directory fails with a confusing "Inconsistent dependency lock file".
- **`-detailed-exitcode`** in automation: 0 = no changes, 2 = changes present, 1 = error. It is the only
  way to distinguish "clean" from "has a diff" programmatically.
- **`-target` is for emergencies**, such as unblocking the CI IAM deadlock in `traps.md` #8. Follow it
  with a full plan to confirm nothing else drifted.

## Things Terraform will not do for you

- **It cannot move a running ECS service** once `ignore_changes = [task_definition]` is set (#1).
  Deployments happen through `update-service`, and the account is the source of truth.
- **It cannot confirm an SNS email subscription** (#18).
- **It cannot fix a policy that denies its own `plan`** (#8).

Each of these is a place where "terraform apply succeeded" and "the change is live" are different
claims. Track applied-vs-committed explicitly (`traps.md` #21).

## Drift you should expect and accept

Out-of-band actors legitimately touch your resources: governance sweepers tagging load balancers,
autoscaling changing counts, CI registering task definitions. Encode those as `ignore_changes` on the
*specific* attributes rather than fighting them on every plan — but keep the ignore list as narrow as
possible. A broad `ignore_changes` hides real drift.
