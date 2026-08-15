// TEMPLATE — ECS task definition + service, hardened. Skeleton, not drop-in.
//
// Every non-obvious line here exists because its absence caused a real defect. See
// references/traps.md — the numbers in comments point at specific entries.

// ---------------------------------------------------------------------------------------------
// Task definition — api
// ---------------------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory

  // ARM64: cheaper per vCPU-hour. Build images with --platform linux/arm64 or tasks fail to start with
  // an exec-format error that reads like a corrupt image.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  // Pulls the image and writes logs. NOT the application's identity.
  execution_role_arn = aws_iam_role.task_exec.arn
  // The application's identity. One per service, least privilege, verified with a NEGATIVE test.
  task_role_arn = aws_iam_role.api_task.arn

  container_definitions = jsonencode([{
    name  = "api"
    image = "${var.ecr_registry}/${var.env}/${var.application_name}-api:${var.image_tag}"

    // traps.md #2: var.image_tag MUST be passed on every apply, set to the tag actually running.
    // A placeholder default writes revisions pointing at images that do not exist in the registry.

    essential = true

    portMappings = [{ containerPort = 8000, protocol = "tcp" }]

    // --- hardening: non-negotiable (references/security.md) ---
    readonlyRootFilesystem = true
    user                   = "1001" // non-root; must match the Dockerfile's USER
    privileged             = false

    // Anything needing to write gets an explicit tmpfs mount, so readonlyRootFilesystem can stay true.
    mountPoints = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]

    // --- config: PATHS, never values (security.md) ---
    environment = [
      { name = "ENVIRONMENT", value = var.env },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_USER", value = var.db_app_user },
      { name = "DB_IAM_AUTH", value = "true" }, // no password exists anywhere
      // Secret PATHS. The app fetches values at runtime through a TTL cache.
      { name = "OIDC_JWKS_URL", value = var.oidc_jwks_url },
      // Bound the pool explicitly — framework defaults are far too generous when every task is a
      // whole extra pool. See references/database.md for the connection-budget maths.
      { name = "DB_POOL_SIZE", value = "3" },
      { name = "DB_MAX_OVERFLOW", value = "2" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }

    // Container-level health check. For a LOAD-BALANCED service the target group is the real gate, but
    // this makes a wedged container visible in ECS as well.
    healthCheck = {
      command     = ["CMD-SHELL", "curl -fsS http://localhost:8000/healthz || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }

    // traps.md #15: Fargate caps stopTimeout at 120 s. Drain must be stop-accepting -> checkpoint ->
    // exit, never finish-in-flight.
    stopTimeout = 120
  }])

  volume {
    name = "tmp"
  }

  tags = { Name = "${local.name_prefix}-api" }
}

// ---------------------------------------------------------------------------------------------
// Service — api
// ---------------------------------------------------------------------------------------------

resource "aws_ecs_service" "api" {
  name            = "${local.name_prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_min_count
  launch_type     = "FARGATE"

  // ECS Exec is an interactive shell inside a task holding your credentials. This is the setting
  // people re-enable to debug and forget to turn off — assert it in acceptance.
  enable_execute_command = false

  network_configuration {
    subnets          = var.private_subnet_ids // PRIVATE. Only the ALB lives in public subnets.
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8000
  }

  // A failed rollout reverts itself instead of leaving a half-updated service.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  // Lets the new task pass health checks before ECS judges it.
  health_check_grace_period_seconds = 60

  // ---- THE MOST IMPORTANT FIVE LINES IN THIS FILE (traps.md #1) ----
  //
  // CI registers new task-definition revisions and calls update-service; autoscaling owns the count.
  // Without this, every apply fights both.
  //
  // CONSEQUENCE YOU MUST INTERNALISE: with this block, `terraform apply` CANNOT move a running
  // service. It will happily register a revision that no service adopts, and report success. A stale
  // running revision then silently diverges from state — this exact situation broke a production code
  // path for days. Always verify the DEPLOYED revision, never the one Terraform just wrote.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.https]
}

// ---------------------------------------------------------------------------------------------
// Worker — no load balancer, no inbound rules at all
// ---------------------------------------------------------------------------------------------

resource "aws_ecs_service" "worker" {
  count = var.worker_enabled ? 1 : 0

  name    = "${local.name_prefix}-worker"
  cluster = aws_ecs_cluster.main.id
  // NOTE: index [0] because of the count above; drop it once the worker is unconditional.
  task_definition = aws_ecs_task_definition.worker[0].arn

  // traps.md #16: if the worker owns ANY scheduled/sweeper duty, its floor is 1, never 0 — otherwise
  // that work silently stops with no error anywhere. Two concurrent sweepers must therefore be safe by
  // construction (SELECT ... FOR UPDATE SKIP LOCKED + advisory locks).
  desired_count = max(var.worker_min_count, 1)

  launch_type            = "FARGATE"
  enable_execute_command = false

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.worker.id] // egress only; no ingress rules exist
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

// ---------------------------------------------------------------------------------------------
// Migrate — a task definition with NO service. Run as a one-off, gating the deploy.
// ---------------------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${local.name_prefix}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  execution_role_arn = aws_iam_role.task_exec.arn
  // Usually the ONLY role permitted to read the DB master secret — it performs owner-level DDL.
  task_role_arn = aws_iam_role.migrate_task.arn

  container_definitions = jsonencode([{
    name = "migrate"
    // Deliberately the API image: migrations ship with the api build, so migration code can never
    // drift from the schema definitions it migrates.
    image     = "${var.ecr_registry}/${var.env}/${var.application_name}-api:${var.image_tag}"
    essential = true
    command   = ["python", "-m", "your_app.migrate"] // override the service entrypoint

    readonlyRootFilesystem = true
    user                   = "1001"

    environment = [
      { name = "ENVIRONMENT", value = var.env },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_MASTER_SECRET_ARN", value = aws_db_instance.main.master_user_secret[0].secret_arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrate.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "migrate"
      }
    }
  }])

  tags = { Name = "${local.name_prefix}-migrate" }
}

// ---------------------------------------------------------------------------------------------
// Autoscaling — cap on the CONNECTION budget, not on CPU (references/database.md)
// ---------------------------------------------------------------------------------------------

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_count
  // A service that scales to 10 tasks and exhausts DB connections is LESS available than one capped
  // at 4. Derive this number from the pool maths, not from load.
  max_capacity = var.api_max_count
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "${local.name_prefix}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 300 // slow to shrink
    scale_out_cooldown = 60  // fast to grow
  }
}

// For the worker, target-track a MATH metric — backlog per task — not raw queue depth. Queue depth
// alone scales wrongly as the task count changes:
//     ApproximateNumberOfMessagesVisible / RunningTaskCount, target ~10
// Requires Container Insights on the cluster for RunningTaskCount to exist.
