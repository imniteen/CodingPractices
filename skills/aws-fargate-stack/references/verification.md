# Verification — acceptance criteria and how to prove each one

A criterion you cannot demonstrate with a command is not a criterion, it is a hope. Every item below has
a check. Run them against the **account**, never against the repository (`traps.md` #20).

## Terraform

- [ ] `terraform validate` and `terraform fmt -check -recursive` clean
- [ ] `plan` is empty on a re-run after apply — i.e. genuinely idempotent

```bash
terraform plan -var-file="dc/$ENV/$TFVARS" -var "image_tag=$RUNNING_TAG" -detailed-exitcode
# 0 = no changes (what you want) · 2 = a diff remains · 1 = error
```

If a diff persists after apply, find out why before moving on. Recurring drift is either an out-of-band
actor you should `ignore_changes` narrowly, or a resource you are configuring wrongly.

- [ ] State bucket has **versioning enabled** and locking configured

```bash
aws s3api get-bucket-versioning --bucket "$STATE_BUCKET"      # expect Status: Enabled
```

## Ingress

- [ ] **Exactly one** internet-facing load balancer exists for this app, and it is the one you created

```bash
aws elbv2 describe-load-balancers --region "$R" \
  --query 'LoadBalancers[?Scheme==`internet-facing`].{name:LoadBalancerName,dns:DNSName,type:Type}' --output table
```

- [ ] HTTP:80 redirects to HTTPS; HTTPS:443 serves the certificate you expect
- [ ] TLS policy is modern (no TLS 1.0/1.1)

```bash
curl -sSI "http://$HOST" | head -3                            # expect 301 to https
curl -sS -o /dev/null -w '%{http_version} %{ssl_verify_result} %{http_code}\n' "https://$HOST"
openssl s_client -connect "$HOST:443" -tls1_1 </dev/null 2>&1 | grep -qi 'alert\|failure' \
  && echo "TLS1.1 refused (good)"
```

- [ ] ALB access logs are landing in S3
- [ ] All target groups report **healthy**

```bash
for TG in $(aws elbv2 describe-target-groups --region "$R" \
      --query "TargetGroups[?starts_with(TargetGroupName,'$PREFIX')].TargetGroupArn" --output text); do
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text
done
```

## WAF

- [ ] A web ACL is **associated with the ALB** — creating one is not attaching it

```bash
aws wafv2 get-web-acl-for-resource --resource-arn "$ALB_ARN" --region "$R" \
  --query 'WebACL.{name:Name,rules:Rules[].Name}' --output json
```

- [ ] Rules are in **block**, not count, mode (after a deliberate count-mode observation period)
- [ ] WAF logging is enabled and a blocked-request alarm exists
- [ ] A known-bad request is actually blocked

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://$HOST/?q=%27%20OR%201%3D1--"   # expect 403
```

## Services and tasks

- [ ] Every service is at desired count, and running the tag you think it is

```bash
for C in api frontend worker; do
  aws ecs describe-services --cluster "$CLUSTER" --services "${CLUSTER}-${C}" \
    --query 'services[0].{svc:serviceName,running:runningCount,desired:desiredCount,td:taskDefinition}' \
    --output json                    # JSON, not text — traps.md #22
done
```

Then resolve each task definition to its image tag. **This is the check that catches drift**: what
Terraform wrote and what the service runs are different facts (`traps.md` #1).

- [ ] Hardening asserted, not assumed

```bash
aws ecs describe-services --cluster "$CLUSTER" \
  --services "${CLUSTER}-api" "${CLUSTER}-frontend" "${CLUSTER}-worker" \
  --query 'services[].{svc:serviceName,exec:enableExecuteCommand,publicIp:networkConfiguration.awsvpcConfiguration.assignPublicIp}' \
  --output table
# expect exec=False and publicIp=DISABLED everywhere
```

- [ ] The latest revision of every family points at an image that **exists in the registry**

```bash
aws ecr list-images --repository-name "$ENV/$APP-api" --region "$R" \
  --query 'imageIds[].imageTag' --output json
```

This is the direct test for `traps.md` #2. A revision referencing a nonexistent tag is a latent outage.

## Database

- [ ] Not publicly accessible, encrypted, in the expected subnets

```bash
aws rds describe-db-instances --db-instance-identifier "$DB" --region "$R" \
  --query 'DBInstances[0].{public:PubliclyAccessible,encrypted:StorageEncrypted,iamAuth:IAMDatabaseAuthenticationEnabled,multiAz:MultiAZ,class:DBInstanceClass,storage:StorageType,deleteProtect:DeletionProtection}' \
  --output json
```

Expect `public=false`, `encrypted=true`, `iamAuth=true`, `storage=gp3`.

- [ ] The RDS security group admits **only task security groups**, no CIDRs

```bash
aws ec2 describe-security-groups --group-ids "$RDS_SG" --region "$R" \
  --query 'SecurityGroups[0].IpPermissions[].{from:FromPort,cidrs:IpRanges[].CidrIp,sgs:UserIdGroupPairs[].GroupId}' \
  --output json
```

Any non-empty `cidrs` here is a finding.

- [ ] Migrations are at head, and `/readyz` says so
- [ ] The app connects with an IAM token and **no password exists anywhere** in task definitions

```bash
aws ecs describe-task-definition --task-definition "${CLUSTER}-api" --region "$R" \
  --query 'taskDefinition.containerDefinitions[0].{env:environment,secrets:secrets}' --output json
```

Read it: env should hold **paths**, never values, and no `PASSWORD`-shaped literal.

## Least privilege — prove the negative

The positive case ("the app works") proves nothing about over-granting. Assert what each role **cannot**
do:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::$ACCT:role/$ENV-$APP-frontend-task-role" \
  --action-names rds-db:connect secretsmanager:GetSecretValue \
  --query 'EvaluationResults[].{action:EvalActionName,decision:EvalDecision}' --output table
# expect implicitDeny / explicitDeny
```

- [ ] frontend role: no AWS permissions
- [ ] api role: cannot receive from the queue, cannot read the master secret
- [ ] api role: lacks whatever third-party grant only the worker needs
- [ ] `iam:PassRole` on the CI deploy role is scoped to **exact** task-role ARNs

Some accounts deny `iam:SimulatePrincipalPolicy` via SCP. If so, inspect the policy documents directly
and say in the record that simulation was unavailable.

## Observability

- [ ] Every alarm exists and is **not** in `INSUFFICIENT_DATA` indefinitely

```bash
aws cloudwatch describe-alarms --region "$R" --alarm-name-prefix "$PREFIX" \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table
```

An alarm stuck in `INSUFFICIENT_DATA` is usually watching a metric that does not exist — a typo in a
dimension, or Container Insights not enabled.

- [ ] **The SNS subscription is `Confirmed`, not `PendingConfirmation`** (`traps.md` #18)

```bash
aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --region "$R" \
  --query 'Subscriptions[].{endpoint:Endpoint,arn:SubscriptionArn}' --output json
```

A `SubscriptionArn` of literally `PendingConfirmation` means **every alarm delivers to nobody.** This is
the single most commonly mis-recorded item in a status document — verify it here, not from prose.

- [ ] Log groups exist with explicit retention, and contain real log lines

## End-to-end canary

The one that matters. A real request through the **public** edge, exercising every layer:

1. Request hits the ALB over HTTPS from outside the VPC
2. WAF allows it; the access log records it
3. The api authenticates it and writes to the database
4. If a worker exists: the queue message is consumed and its effect is durable
5. The result is visible in the UI

Then the negative: **stop the worker and repeat.** Whatever your durability invariant is — the row is
still written, the message is still queued — must hold with the consumer down. If it does not, you have
an at-most-once path where you assumed at-least-once.

## Record the result

Write into the project's status document, per item: what was checked, the **command**, the **date**, and
the outcome. Then separately list:

- what is **committed but not applied**
- what is **applied but not verified**
- what is **waiting on another team**

Those three lists are the ones that rot silently. One project carried a correct, reviewed IAM fix for two
days while CI failed on exactly the problem it fixed, because nothing distinguished "merged" from
"applied" (`traps.md` #21).
