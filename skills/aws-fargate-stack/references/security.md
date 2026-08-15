# Security — a public app has no network perimeter to hide behind

An internal-only app can lean on the network as a control. This one cannot. Everything below replaces
that missing layer, and none of it is optional.

## The edge

### TLS and the listener

- HTTPS:443 with an ACM certificate **in the ALB's region**. HTTP:80 exists only to redirect (301).
- An explicit modern SSL policy — do not inherit the default, which has historically permitted TLS 1.0.
- `drop_invalid_header_fields = true` on the ALB.
- `deletion_protection = true`. A public entry point should not be one `terraform destroy` from gone.
- **Access logs to S3, enabled from day one.** After an incident is too late to start collecting them.

### WAF — managed rules *and* a rate limit

A rate limit alone is not protection; managed rule groups alone do not stop volumetric abuse. Attach a
WAFv2 web ACL to the ALB with:

- `AWSManagedRulesCommonRuleSet`
- `AWSManagedRulesKnownBadInputsRuleSet`
- `AWSManagedRulesSQLiRuleSet` if you speak SQL (you do)
- `AWSManagedRulesAmazonIpReputationList`
- A **rate-based rule** per source IP, sized to real traffic
- Optional geo-match or IP allowlist if the operator said access is restricted

Two operational rules:

1. **Run in `count` mode first**, read the logs, then flip to `block`. Managed rules produce false
   positives on file uploads, rich text, and anything base64-ish — discovering that in blocking mode
   means discovering it as a user-visible outage.
2. **Enable WAF logging** and alarm on a blocked-request spike. That metric is both an attack signal and
   your early warning that a rule change broke legitimate traffic.

### Authentication at the edge

Authenticate **before** the app trusts anything. Two viable shapes:

- **ALB OIDC authentication** — the listener performs the OIDC dance; the app receives signed identity
  headers. Least app code, but coarse: it is all-or-nothing per listener rule.
- **In-app OIDC with a verified bearer token** — more code, far more control.

If you verify tokens in the app, these are the details that decide whether it is real security:

- **Pin the algorithm to an allowlist** (`["RS256"]`). Accepting whatever the token's header claims
  admits `alg=none` and HS256-signed-with-the-public-key confusion.
- **Verify `iss` and `aud`, and require `exp`.** `aud` is *not* the client id in every provider — many
  authorization servers issue a distinct audience, and conflating the two produces a bare 401 that is
  painful to diagnose.
- **Resolve authorization from your own datastore**, keyed on the token's `sub` — never from a
  role/group claim the client could influence.
- **Reject cleanly, fail loudly.** A malformed or expired token is a 401. A *misconfigured verifier*
  (unreachable JWKS, missing key) must be a 500, never a silent pass. Distinguish the two exception
  classes explicitly — this is the difference between "denied" and "open".
- **JWKS caching with a bounded lifetime**, so key rotation is picked up without a redeploy.

Test the attacks, not the happy path: forged signature, `alg=none`, HS256-with-public-key, expired,
wrong `aud`, wrong `iss`, missing `exp`. Each must be rejected.

**Do not ship a placeholder verifier.** A stub that returns "no verifier configured" produces a console
that 500s on every call — and the tempting "fix" of returning an anonymous admin is how an app ends up
open. If auth is not ready, fail closed and say so.

### Security headers

Set at the app or edge: HSTS, `X-Content-Type-Options: nosniff`, a real `Content-Security-Policy`,
`Referrer-Policy`, and `X-Frame-Options`/`frame-ancestors`. Cheap, and their absence is the first thing
any scan reports.

## Task roles — one per service, and prove the negative

| Service | Should have | Must NOT have |
|---|---|---|
| frontend | nothing | any AWS permission at all |
| api | DB connect, its own secrets by exact ARN, queue **send** | queue receive, anything the worker alone needs |
| worker | DB connect, its own secrets, queue **receive/delete**, any third-party API grant | inbound anything |
| migrate | master secret + KMS decrypt | runtime app grants |
| execution role | ECR pull + log write | application permissions |

Rules:

- **Exact resource ARNs for secrets.** `ssm:GetParameter` on
  `arn:aws:ssm:…:parameter/app/env/thing` — never `parameter/app/*`. A path wildcard grants every secret
  you add in future to a role that had no business seeing it.
- **`iam:PassRole` scoped to exact task-role ARNs.** Broad `PassRole` plus `RegisterTaskDefinition`
  equals arbitrary code as any role (`traps.md` #9).
- **Assert the negative in acceptance.** "The api role cannot invoke the service only the worker needs"
  is a test, not a comment. Least privilege you have not verified is least privilege you do not have.

## Task hardening

Non-negotiable on every task definition:

```
enable_execute_command  = false      # ECS Exec is an interactive shell into a task with your creds
readonlyRootFilesystem  = true       # add explicit tmpfs volumes where genuinely needed
user                    = "1001"     # non-root, set in the Dockerfile
privileged              = false
assign_public_ip        = DISABLED
```

`enable_execute_command = false` is the one people quietly re-enable to debug and forget to turn off.
Assert it in acceptance:

```bash
aws ecs describe-services --cluster "$C" --services "$C-api" "$C-worker" "$C-frontend" \
  --query 'services[].{svc:serviceName,exec:enableExecuteCommand}' --output table
```

## Secrets

- Env carries **paths**, never values. Fetch at runtime with a TTL cache.
- A secret that no role can read is not "secure", it is broken — and a role that can read a *signing*
  key when it only needs to *verify* is over-granted. Split them: publish the public key where the
  verifier can read it, and grant the private key to nobody at runtime.
- Rotation: know how each secret rotates, and whether the app tolerates rotation mid-flight.

## Images

- `scanOnPush = true` on every ECR repository — often your only CVE signal if Inspector is not enabled.
- **Immutable tags**, tagged by commit SHA. A bad tag can never be reclaimed (`traps.md` #24), so record
  which tags must never be deployed.
- Multi-stage builds; ship no build toolchain in the runtime layer.
- Pin base images by digest for reproducibility.

## Compliance gaps worth naming out loud

Enterprise accounts frequently lack Security Hub, AWS Config recorders, and Inspector. If so, say so in
the project's status document rather than assuming coverage. Compensating controls that cost nothing:

- ECR `scanOnPush`
- A CloudTrail + EventBridge rule alerting on **"internet-facing load balancer created"** — for an app
  where exactly one is expected, a second is a real signal
- Terraform plan review as the drift gate
- GuardDuty if it is already on (enabling it usually needs the security team)

## Threat notes specific to this topology

| Risk | Mitigation |
|---|---|
| The ALB is a public attack surface | WAF in block mode, rate limiting, access logs, alarms on 5xx and blocked spikes |
| Credential theft from a task | Exact-ARN grants, no Exec, readonly rootfs, short-lived DB tokens rather than passwords |
| CI as an escalation path | Exact-ARN `PassRole`, protected branches, no fork-MR pipelines — **before** granting deploy rights |
| Shared account with other teams' CI | Account-level IAM isolation still holds, but assume a neighbouring over-permissioned role exists; do not rely on account boundaries you do not own |
| Public app enumerating data via auth bypass | Authorization from your datastore, not from claims; test the negative |
