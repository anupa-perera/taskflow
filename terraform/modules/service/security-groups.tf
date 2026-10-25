# Traffic is allowed only along the request path: internet -> ALB -> tasks -> RDS. Image pulls,
# secrets and logs go through the host's network, not the task ENI, so tasks need nothing else.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public HTTP in; out to TaskFlow tasks only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  ip_protocol       = "tcp"
  from_port         = local.http_port
  to_port           = local.http_port
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Requests and health checks to tasks"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.tasks.id
}

# Shared by the API and migration tasks; the migration task listens on nothing.
resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "TaskFlow tasks: in from the ALB only; out to RDS only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-tasks" }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Requests and health checks from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_db" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "PostgreSQL"
  ip_protocol                  = "tcp"
  from_port                    = var.database.port
  to_port                      = var.database.port
  referenced_security_group_id = var.database.security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = var.database.security_group_id
  description                  = "PostgreSQL from TaskFlow tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.database.port
  to_port                      = var.database.port
  referenced_security_group_id = aws_security_group.tasks.id
}
