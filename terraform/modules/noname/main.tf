# Noname (Akamai API Security) sensor — deployed as a DaemonSet on the ECS EC2
# cluster (one task per host). Sniffs traffic on each host's network interfaces
# (default BPF: tcp and not tcp port 443) and forwards API packet pairs to the
# Noname engine over TLS.
#
# Network mode "host" + PID mode "host" let the sensor see all traffic crossing
# the host NIC and (with eBPF enabled) hook SSL libraries on neighbouring
# containers. Linux capabilities NET_ADMIN/NET_RAW/SYS_NICE are required for
# packet capture; eBPF mode adds SYS_ADMIN/SYS_PTRACE.
#
# The sensor image lives in a private Google Cloud Artifact Registry. The
# Noname deployment script supplies a JSON service-account key that we store
# in AWS Secrets Manager and reference via the task definition's
# repositoryCredentials block.

resource "aws_iam_role" "noname_task_exec" {
  name = "${var.project_name}-noname-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "noname_task_exec" {
  role       = aws_iam_role.noname_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_secretsmanager_secret" "jfrog_credentials" {
  name        = "/${var.project_name}/noname/jfrog-credentials"
  description = "Noname sensor image registry credentials (Google Cloud Artifact Registry SA key) from the AWS ECS deployment script"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "jfrog_credentials" {
  secret_id     = aws_secretsmanager_secret.jfrog_credentials.id
  secret_string = var.noname_jfrog_credentials_json
}

resource "aws_iam_policy" "noname_secrets" {
  name = "${var.project_name}-noname-secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.jfrog_credentials.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "noname_secrets" {
  role       = aws_iam_role.noname_task_exec.name
  policy_arn = aws_iam_policy.noname_secrets.arn
}

resource "aws_cloudwatch_log_group" "noname" {
  name              = "/ecs/${var.project_name}/noname"
  retention_in_days = 7
  tags              = var.tags
}

locals {
  # eBPF mode needs to read /proc and load BPF programs — extra capabilities
  # plus bind mounts of the host root and the docker socket. Sniffing-only
  # mode just needs raw packet capture, no mounts.
  capabilities_no_ebpf = ["SYS_NICE", "NET_ADMIN", "NET_RAW"]
  capabilities_ebpf    = concat(local.capabilities_no_ebpf, ["SYS_ADMIN", "SYS_PTRACE"])

  ebpf_volumes = [
    { name = "host_root", host_path = "/" },
    { name = "docker_socket", host_path = "/var/run/docker.sock" },
  ]
  ebpf_mount_points = [
    { sourceVolume = "host_root", containerPath = "/host", readOnly = false },
    { sourceVolume = "docker_socket", containerPath = "/var/run/docker.sock", readOnly = false },
  ]
}

resource "aws_ecs_task_definition" "noname" {
  family                   = "${var.project_name}-noname-sensor"
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  pid_mode                 = "host"
  execution_role_arn       = aws_iam_role.noname_task_exec.arn

  dynamic "volume" {
    for_each = var.noname_should_use_ebpf ? local.ebpf_volumes : []
    content {
      name      = volume.value.name
      host_path = volume.value.host_path
    }
  }

  container_definitions = jsonencode([
    {
      name      = "noname-sensor"
      image     = var.noname_sensor_image
      cpu       = 256
      memory    = 512
      essential = true
      user      = "root"

      repositoryCredentials = {
        credentialsParameter = aws_secretsmanager_secret.jfrog_credentials.arn
      }

      entryPoint = var.noname_should_use_ebpf ? ["/sensor/ebpf_entry_point.sh"] : null

      environment = [
        { name = "ENGINE_URL",         value = var.noname_engine_url },
        { name = "SNIFF_SOURCE_TYPE",  value = tostring(var.noname_sniff_source_type) },
        { name = "SNIFF_SOURCE_INDEX", value = tostring(var.noname_sniff_source_index) },
        { name = "SNIFF_SOURCE_KEY",   value = var.noname_sniff_source_key },
        { name = "SHOULD_USE_EBPF",    value = tostring(var.noname_should_use_ebpf) },
        { name = "LIBS_TO_HOOK",       value = "libssl libcrypto libpthread libc ld" },
      ]

      mountPoints = var.noname_should_use_ebpf ? local.ebpf_mount_points : []

      linuxParameters = {
        capabilities = {
          add = var.noname_should_use_ebpf ? local.capabilities_ebpf : local.capabilities_no_ebpf
        }
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.noname.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "noname"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "noname" {
  name                = "${var.project_name}-noname-sensor"
  cluster             = var.cluster_id
  task_definition     = aws_ecs_task_definition.noname.arn
  launch_type         = "EC2"
  scheduling_strategy = "DAEMON"

  tags = var.tags
}
