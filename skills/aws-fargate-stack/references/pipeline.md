# Images and CI — GitLab pipeline for a Fargate stack

## Stage order

```
gate → test → build ×N → tf-plan → tf-apply → migrate → deploy → smoke
```

Two principles:

1. **Whatever must never regress runs FIRST and is never manual.** If a project has a security or
   correctness boundary, its test suite is stage 1, non-manual, blocking everything downstream. Make it
   cheap to install so this costs seconds.
2. **Everything that touches AWS is `when: manual`** until protected branches and fork-MR blocking are
   in place. `PassRole` plus `RegisterTaskDefinition` is arbitrary code as a task role
   (`traps.md` #9) — earn automation, do not assume it.

## Read `traps.md` #10 before writing any `needs:`

The highest-severity CI mistake available. Short version: a job with **no** `rules`/`only`/`except`
falls back to `only: [branches, tags]` and is **absent from merge-request pipelines**. A job that *has*
`rules` is present. A `needs:` from a present job to an absent one makes the MR pipeline
**uncreatable** — "0 jobs", `yaml invalid` — so even the mandatory first-stage gate never runs.

Defend structurally:

```yaml
smoke:
  needs:
    - job: deploy
      optional: true          # only relaxes when the job is absent from the pipeline entirely
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      when: never             # smoke asserts LIVE state; meaningless on an unmerged branch
    - when: on_success
```

Audit the whole file, not just the job you are editing:

```python
# For every job: does it have rules? does anything it `needs` lack rules?
# A present job depending on an absent one is a pipeline-creation error.
```

## Two identities, split by blast radius

| Variable | Role | Scope |
|---|---|---|
| `TF_AWS_ROLE_ARN` | terraform | Broad, manual-gated |
| `DEPLOY_AWS_ROLE_ARN` | deploy | Narrow: ECR push, `RegisterTaskDefinition`, `UpdateService`, `RunTask`, exact-ARN `PassRole` |

Set them as **yml `variables:`** with real defaults rather than relying on project variables alone. If a
required variable is unset, OIDC fails with `Invalid length for parameter RoleArn, value: 0`, which reads
like a broken template rather than a missing variable. Project-level variables still override yml
(lowest precedence), so per-environment overrides cost nothing.

The trust policy should pin the **project path** so a pipeline in any other project cannot assume the
role — which is what makes it safe to have the ARNs in a committed file.

## Tag resolution

```yaml
.resolve-tag: &resolve-tag |
  if [ -z "${IMAGE_TAG}" ]; then export IMAGE_TAG="${CI_COMMIT_SHORT_SHA}"; fi
  echo "IMAGE_TAG=${IMAGE_TAG}"
```

Commit SHA by default, overridable for a rebuild or rollback. **Never `latest`.**

## Registering a revision without Terraform

Deployments mutate the image and nothing else, so read the current definition, patch the image, and
register:

```bash
register_revision() {
  local family="$1" image="$2"
  aws ecs describe-task-definition --task-definition "$family" --query 'taskDefinition' --output json \
    | jq --arg IMG "$image" '
        .containerDefinitions[0].image = $IMG
        | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
              .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)' \
    > /tmp/td.json
  aws ecs register-task-definition --cli-input-json file:///tmp/td.json \
    --query 'taskDefinition.taskDefinitionArn' --output text
}
```

This is *why* services declare `ignore_changes = [task_definition]`. Note the consequence: because CI
always overrides the image, CI is immune to the placeholder-tag trap while **local applies are not**
(`traps.md` #2, #3).

## Migrate, then deploy

```bash
TD_ARN=$(register_revision "${CLUSTER}-migrate" "$API_IMAGE")

NETCFG=$(aws ecs describe-services --cluster "$CLUSTER" --services "${CLUSTER}-api" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration' --output json)
SUBNETS=$(echo "$NETCFG" | jq -r '.subnets | join(",")')
SGS=$(echo "$NETCFG" | jq -r '.securityGroups | join(",")')

TASK_ARN=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TD_ARN" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SGS}],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"
EXIT=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)
test "$EXIT" = "0"        # a failed migration must stop the pipeline before any service is updated
```

Deriving the network config from the api service is deliberate — it cannot drift from what Terraform
granted RDS ingress to.

Then deploy and **wait for the outcome**, so the pipeline reflects the circuit breaker's verdict rather
than reporting success on a rollout that later rolled back:

```bash
for C in api frontend worker; do
  TD=$(register_revision "${CLUSTER}-${C}" "${REGISTRY}/${ENV}/${APP}-${C}:${IMAGE_TAG}")
  aws ecs update-service --cluster "$CLUSTER" --service "${CLUSTER}-${C}" --task-definition "$TD" >/dev/null
done
aws ecs wait services-stable --cluster "$CLUSTER" \
  --services "${CLUSTER}-api" "${CLUSTER}-frontend" "${CLUSTER}-worker"
```

## Build

ARM64 on an ARM runner where available; emulated cross-builds are slow enough to change behaviour on
timeouts.

```bash
buildah build --platform linux/arm64 -f "$DOCKERFILE" $BUILD_ARGS \
  -t "${REPO}:${IMAGE_TAG}" .
buildah push "${REPO}:${IMAGE_TAG}"
```

**Build-time frontend config must be `--build-arg`** (`traps.md` #13). Runtime env is too late — the
value is already inlined in the bundle.

Gate build jobs on `changes:` so unrelated commits skip them — but know that `changes:` rules make those
jobs **present in MR pipelines** (`traps.md` #11). Even `when: manual`, one click pushes an image from
an unmerged ref using the deploy role. Audit that before enabling protected branches.

## Deploying all services on one tag

Even when only one image changed, prefer rebuilding and deploying **all** services on a single tag.
Mixed tags across services are legitimate but they make "what is running?" a per-service question, and
that ambiguity has caused real confusion. One tag, one answer.

## Smoke

Assert what is reachable from where the runner actually is. A shared runner in another account/region
may not reach a private endpoint at all, in which case split:

- **Control-plane assertions** via AWS APIs (reachable anywhere): services at desired count, target
  groups healthy, `enableExecuteCommand: false`.
- **One real HTTP assertion** against the public ALB hostname.

Say plainly in a comment what smoke does *not* cover, so nobody reads green as end-to-end proof.

## Ordering when enabling CI apply

Strict dependency order — each step is unsafe without the previous:

1. **State locking + bucket versioning** (`traps.md` #7)
2. **Protected branches + fork-MR pipelines blocked** (`traps.md` #9)
3. Role ARN variables set, apply un-gated

## Local verification before the first pipeline

Run every gate locally first (`traps.md` #12). A lint or type gate you have never run will fail the very
first pipeline, before it reaches build or deploy, and that failure looks like a broken pipeline rather
than pre-existing findings.
