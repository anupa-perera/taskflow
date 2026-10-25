resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  # Removes headers that are not valid HTTP instead of forwarding them (request smuggling).
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name}-api"
  vpc_id      = var.vpc_id
  target_type = "ip"
  protocol    = "HTTP"
  port        = local.container_port
  # Longer than any request can run (statement timeout 5 s), so draining never cuts one off.
  deregistration_delay = local.deregistration_delay_seconds

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = local.health_check_interval_seconds
    timeout             = local.health_check_timeout_seconds
    healthy_threshold   = local.healthy_threshold
    unhealthy_threshold = local.unhealthy_threshold
  }
}

# ponytail: plain HTTP; no domain for an ACM certificate. Upgrade: ACM certificate, an HTTPS
# listener and a redirect from this one (.trivyignore.yaml AWS-0054).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = local.http_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
