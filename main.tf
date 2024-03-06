provider "aws" {
  region = "us-west-2"
}

resource "aws_route53_zone" "domain" {
  name = "owens-monitor.space"
}

output "nameservers" {
  value = aws_route53_zone.domain.name_servers
}

data "aws_route53_zone" "domain" {
  name = aws_route53_zone.domain.name
}

resource "aws_acm_certificate" "cert" {
  domain_name       = "owens-monitor.space"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.domain.zone_id
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_vpc" "vpc1" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "subnet1" {
  vpc_id            = aws_vpc.vpc1.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2b"
}

resource "aws_security_group" "security_group_uptime_kuma" {
  name   = "Security Group for Uptime Kuma"
  vpc_id = aws_vpc.vpc1.id

  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "security_group_efs" {
  name   = "efs-sg"
  vpc_id = aws_vpc.vpc1.id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_security_group.security_group_uptime_kuma.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "uptime_kuma_alb" {
  name               = "uptime-kuma-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.security_group_uptime_kuma.id]
  subnets            = [aws_subnet.subnet1.id]

  enable_deletion_protection = false

  tags = {
    Name = "uptime-kuma-alb"
  }
}

resource "aws_lb_target_group" "uptime_kuma_tg" {
  name        = "uptime-kuma-tg"
  port        = 3001
  protocol    = "HTTP"
  vpc_id      = aws_vpc.vpc1.id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb_listener" "uptime_kuma_listener" {
  load_balancer_arn = aws_lb.uptime_kuma_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.uptime_kuma_tg.arn
  }
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "my-cluster"
}

resource "aws_ecs_task_definition" "uptime_kuma" {
  family                   = "uptime-kuma-family"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  cpu                      = "256"
  memory                   = "512"
  runtime_platform {
    operating_system_family = "LINUX"
  }

  volume {
    name = "uptime-kuma-data"

    efs_volume_configuration {
      file_system_id = aws_efs_file_system.efs.id
      root_directory = "/data"

      transit_encryption      = "ENABLED"
      transit_encryption_port = 2049
    }
  }

  container_definitions = jsonencode([
    {
      name      = "uptime-kuma",
      image     = "louislam/uptime-kuma:1",
      cpu       = 256,
      memory    = 512,
      essential = true,
      portMappings = [
        {
          containerPort = 3001,
          hostPort      = 3001,
          protocol      = "tcp"
        }
      ],
      execute_command_configuration = {
        logging = "DEFAULT"
      }
      mountPoints = [
        {
          sourceVolume  = "uptime-kuma-data"
          containerPath = "/app/data"
          readOnly      = false
        },
      ]
    }
  ])
}

resource "aws_ecs_service" "uptime-kuma_service" {
  name            = "uptime-kuma-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.uptime_kuma.arn
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.uptime_kuma_tg.arn
    container_name   = "uptime-kuma"
    container_port   = 3001
  }

  network_configuration {
    subnets          = [aws_subnet.subnet1.id]
    assign_public_ip = false
    security_groups  = [aws_security_group.security_group_uptime_kuma.id]
  }

  desired_count = 1
}

resource "aws_efs_file_system" "efs" {
  creation_token = "uptime-kuma-efs"

  tags = {
    Name = "UptimeKumaEFS"
  }
}

resource "aws_efs_mount_target" "efs_mt" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = aws_subnet.subnet1.id
  security_groups = [aws_security_group.security_group_efs.id]
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
