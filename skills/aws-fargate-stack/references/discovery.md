# Phase 0 — discovery sweep and the IP-budget gate

**Nothing in this skill is pre-filled for an account.** Phase 0 asks the operator where to deploy, then
*verifies* every identifier read-only before a single resource is written. Its output is a durable facts
table in the project, each row carrying the date it was checked.

Why this is a gate and not a formality: a wrong subnet id, a certificate in the wrong region, or a
private zone that is not associated with the VPC all produce a plan that **applies cleanly and fails at
runtime**. Discovery is cheaper than that debugging session by an order of magnitude.

## Step 1 — ask, do not assume

Ask the operator, one at a time, and record the answers:

1. **Which AWS account and region?** Get the account *number*, not a nickname — profile names and
   account aliases drift.
2. **Environment posture.** Recommend nonprod first, prod additive. Confirm whether a prod account
   already exists or must be bootstrapped separately.
3. **Hostname** the app will serve on, and **which hosted zone** owns it.
4. **DB sizing and HA** — see `database.md` for the connection-budget math that follows from it.
5. **Worker now or later?** Design the seam either way.
6. **Who may reach it** — everyone, geo-restricted, IP-allowlisted, or authenticated-only.

Confirm the profile actually resolves to the account they named before running anything else:

```bash
aws sts get-caller-identity --output json
```

## Step 2 — the sweep

All read-only. Substitute the region throughout.

### Network

```bash
# VPCs and their CIDRs — a single small CIDR is the constraint that shapes everything
aws ec2 describe-vpcs --region "$R" \
  --query 'Vpcs[].{id:VpcId,cidr:CidrBlock,name:Tags[?Key==`Name`].Value|[0],default:IsDefault}' \
  --output table

# Subnets WITH free-address counts and public/private posture — the numbers that gate the design
aws ec2 describe-subnets --region "$R" --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].{az:AvailabilityZone,id:SubnetId,cidr:CidrBlock,free:AvailableIpAddressCount,autoPublicIp:MapPublicIpOnLaunch}' \
  --output table

# Route tables — which subnets are genuinely public (0.0.0.0/0 -> igw) vs private (-> nat)
aws ec2 describe-route-tables --region "$R" --filters "Name=vpc-id,Values=$VPC" \
  --query 'RouteTables[].{id:RouteTableId,assoc:Associations[].SubnetId,routes:Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId]}' \
  --output json

aws ec2 describe-nat-gateways --region "$R" --filter "Name=vpc-id,Values=$VPC" \
  --query 'NatGateways[].{id:NatGatewayId,subnet:SubnetId,state:State,ip:NatGatewayAddresses[0].PublicIp}' --output table

aws ec2 describe-vpc-endpoints --region "$R" --filters "Name=vpc-id,Values=$VPC" \
  --query 'VpcEndpoints[].{svc:ServiceName,type:VpcEndpointType,state:State}' --output table
```

An internet-facing ALB needs **public subnets in at least two AZs**, each with an IGW default route.
Verify that from the route tables — `MapPublicIpOnLaunch` is a hint, not proof.

### Certificate and DNS

```bash
# The cert MUST be in the ALB's region. (us-east-1 is required only for CloudFront.)
aws acm list-certificates --region "$R" \
  --query 'CertificateSummaryList[].{arn:CertificateArn,domain:DomainName,status:Status}' --output table

# Public vs private zones of the same name is common — pick deliberately
aws route53 list-hosted-zones --query 'HostedZones[].{id:Id,name:Name,private:Config.PrivateZone,records:ResourceRecordSetCount}' --output table
```

For a **public** app you need a **public** zone and a cert whose domain covers the hostname. If both a
public and private zone exist for the same name (split-horizon), a record in the wrong one resolves
internally and nowhere else. Check for an existing wildcard record that your specific record must beat.

### Capability and precedent

```bash
aws ecs list-clusters --region "$R" --output table            # is ECS already in use here?
aws rds describe-db-instances --region "$R" \
  --query 'DBInstances[].{id:DBInstanceIdentifier,class:DBInstanceClass,engine:Engine,multiAz:MultiAZ}' --output table
aws elbv2 describe-load-balancers --region "$R" \
  --query 'LoadBalancers[].{name:LoadBalancerName,scheme:Scheme,type:Type}' --output table
aws s3api get-bucket-versioning --bucket "$STATE_BUCKET"      # trap #7
aws iam list-open-id-connect-providers                        # is a CI OIDC provider already registered?
```

Existing workloads of the same shape are the strongest evidence that no service-enablement or SCP
surprise awaits. Absence is not a blocker but raises the value of a throwaway apply (phase 0b).

### Guardrails that will bite later

```bash
aws organizations describe-organization 2>&1 | head -5   # often denied; the error itself is informative
aws iam get-account-authorization-details --filter Role --max-items 1 >/dev/null 2>&1 || echo "restricted"
```

Note any permission boundary or SCP on your own principal. One real environment denies
`iam:SimulatePrincipalPolicy`, which removes a verification tool you would otherwise rely on.

## Step 3 — the IP-budget gate

**This is the one hard constraint that has actually blocked a design.** Small VPC CIDRs are common in
enterprise accounts, and Fargate consumes one VPC IP per task.

A **public-facing** topology splits the demand across subnet tiers — different from an internal-only
app, where everything lands in private subnets:

**Public subnets** (ALB only):
- Internet-facing ALB: AWS wants **≥8 free addresses per subnet** for scaling events. Budget 8–16 per
  AZ, and treat that as a floor, not an estimate.

**Private subnets** (everything else):
- Fargate tasks: `api_max + frontend_max + worker_max` (autoscaling maxima, not current counts)
- One-off migration task: 1
- RDS: 1 single-AZ, 2 Multi-AZ
- Each interface VPC endpoint: **1 ENI per subnet it is placed in**

Compute it explicitly and write the arithmetic into the facts table:

```
private demand = tasks_at_max + 1 + rds_enis + (interface_endpoints × subnets)
public  demand = 8..16 per AZ
```

**Refuse to proceed if the margin is thin.** Guidance:

| Utilisation of free addresses | Action |
|---|---|
| < 50% | Proceed |
| 50–70% | Proceed, but cap autoscaling maxima and justify every interface endpoint |
| > 70% | **Stop.** Choose a different VPC, or a different account |

Two footguns here:

- **A subnet with a handful of free addresses is unusable, not "tight".** One real VPC had a /27 with 4
  free — a tag-based subnet lookup would have silently included it and the third AZ would have failed
  to place tasks. Enumerate subnets explicitly; never select them by tag.
- **Do not add a secondary VPC CIDR to escape this.** Enterprise VPCs are usually IaC-managed by
  another team, and changing the CIDR is the one action that turns a self-serve deployment into a
  cross-team dependency.

Every additional interface endpoint costs 2 ENIs (two AZs). Keep them to the flows that genuinely must
avoid the public internet; everything else can egress via NAT.

## Step 4 — write the facts table

```markdown
## Verified environment facts (<date>, read-only sweep)

| Fact | Value |
|---|---|
| Account / region | 1234… / us-west-2 |
| VPC | vpc-… (10.x.y.0/24, single CIDR, IaC-managed by <team>) |
| Public subnets (ALB) | 2a subnet-… (N free) · 2c subnet-… (N free) |
| Private subnets (tasks/RDS) | 2a subnet-… (N free) · 2c subnet-… (N free) |
| Excluded subnets | 2b subnet-… — only N free, DO NOT USE |
| NAT / egress IPs | … |
| Certificate | arn:…  (covers <host>, ISSUED, region matches ALB) |
| Public hosted zone | Z… (<name>, N records; wildcard present? yes/no) |
| State backend | s3://… — versioning: on/off · locking: yes/no |
| IP budget | private X of Y (Z%) · public A of B — PASS/FAIL |
| Access / guardrails | <role>, boundary?, SCP denials observed |
```

Then, optionally but cheaply: **phase 0b, a throwaway apply** — an empty ECS cluster and one task
definition, then destroy. It costs minutes and retires every "is this service even enabled here"
question before you have 100 resources to debug.
