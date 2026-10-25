# Evidence

Captured from the live `taskflow-prod` stack in account 621574609594, `ap-south-1`, on 2026-10-25.

## Infrastructure (AWS console)

| File                                                                     | Shows                                                                                                        |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| [aws/01-vpc-resource-map.jpg](aws/01-vpc-resource-map.jpg)               | VPC `10.0.0.0/16` with public and private subnets in ap-south-1a and 1b, and their route tables              |
| [aws/02-ecs-cluster.jpg](aws/02-ecs-cluster.jpg)                         | ECS cluster `taskflow-prod`: 1 active service, 2 running tasks, 2 container instances, Container Insights on |
| [aws/03-ecs-container-instances.jpg](aws/03-ecs-container-instances.jpg) | The EC2 capacity provider and two `t3.small` hosts, one per Availability Zone                                |
| [aws/04-ecs-service-health.jpg](aws/04-ecs-service-health.jpg)           | Service `taskflow-prod-api` on revision 1, deployment succeeded, 2 healthy load balancer targets             |
| [aws/05-alb.jpg](aws/05-alb.jpg)                                         | Internet-facing load balancer across two zones, its public DNS name, and the HTTP:80 listener                |
| [aws/06-alb-target-health.jpg](aws/06-alb-target-health.jpg)             | Target group: two task IPs on port 3000, one per private subnet, both healthy                                |
| [aws/07-rds.jpg](aws/07-rds.jpg)                                         | RDS PostgreSQL `taskflow-prod`, available, not publicly accessible, master credentials in Secrets Manager    |
| [aws/08-ecr-image.jpg](aws/08-ecr-image.jpg)                             | ECR image tagged with the commit SHA `43aca090`                                                              |
| [aws/09-cloudwatch-app-logs.jpg](aws/09-cloudwatch-app-logs.jpg)         | Application JSON logs in CloudWatch, one entry expanded: request id, status 200, response time               |

## Application through the load balancer

| File                                                                                                                                                                                                 | Shows                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [app/requests-through-alb.txt](app/requests-through-alb.txt)                                                                                                                                         | Full request and response transcripts against the ALB DNS name: `/health`, list, create (201) and a validation error (400, `application/problem+json`) |
| [app/app-health-through-alb.png](app/app-health-through-alb.png), [app/app-tasks-through-alb.png](app/app-tasks-through-alb.png), [app/app-openapi-through-alb.png](app/app-openapi-through-alb.png) | The same endpoints and the OpenAPI UI in a browser                                                                                                     |

## Host configuration (Ansible)

| File                                                                                 | Shows                                                                                                                                            |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| [ansible/inventory-graph.txt](ansible/inventory-graph.txt)                           | The aws_ec2 dynamic inventory finding both hosts by tag, with no IP lists                                                                        |
| [ansible/run-1.txt](ansible/run-1.txt)                                               | First playbook run: `changed=29 failed=0` on each host, one host at a time                                                                       |
| [ansible/availability-during-run-1.txt](ansible/availability-during-run-1.txt)       | `/health` through the ALB once a second during run 1: 773 responses, all 200, while each host was drained and Docker restarted                   |
| [ansible/run-2.txt](ansible/run-2.txt)                                               | Second run: `changed=0 failed=0` on both hosts, so the playbook is idempotent                                                                    |
| [ansible/host-verification.txt](ansible/host-verification.txt)                       | On the hosts afterwards: the firewall table next to ECS's intact rules, `ecs.config`, effective sshd settings, the pinned release, `daemon.json` |
| [ansible/10-host-logs-cloudwatch.jpg](ansible/10-host-logs-cloudwatch.jpg)           | Host log group (2-week retention) with ECS agent, ECS init, ECS audit and dnf streams from both hosts                                            |
| [ansible/11-host-memory-metrics.jpg](ansible/11-host-memory-metrics.jpg)             | Memory metrics from the CloudWatch agent, starting when run 1 configured each host                                                               |
| [ansible/12-fleet-manager-ssm-online.jpg](ansible/12-fleet-manager-ssm-online.jpg)   | Both hosts online in Systems Manager, the only way in (no SSH)                                                                                   |
| [ansible/13-host-role-scoped-policies.jpg](ansible/13-host-role-scoped-policies.jpg) | Host role with a scoped `cloudwatch-agent` policy instead of `CloudWatchAgentServerPolicy`                                                       |

## Terraform

| File                                                                     | Shows                                                                                       |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| [terraform/apply-ansible-bucket.txt](terraform/apply-ansible-bucket.txt) | `terraform apply` adding the Ansible transfer bucket and the scoped CloudWatch agent policy |

## Scaling: a vertical scaling event under real load

Start with [scaling/00-summary.txt](scaling/00-summary.txt), the timeline in UTC. Real traffic
through the ALB scaled the service out from 2 tasks to the maximum of 4. At 4 tasks it stayed
saturated, so the composite alarm fired and the scaler stepped every task from 256/512 to 512/768
(CPU units / MiB).

| File                                                                                                                                                                       | Shows                                                                                                                                                                              |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [scaling/before-2-task-size-256-512.jpg](scaling/before-2-task-size-256-512.jpg), [before-1-task-definition-revisions.jpg](scaling/before-1-task-definition-revisions.jpg) | **Before**: only revision 1 exists, at 256 CPU / 512 MiB                                                                                                                           |
| [scaling/before-3-alarms-ok.jpg](scaling/before-3-alarms-ok.jpg), [before-4-service-auto-scaling.jpg](scaling/before-4-service-auto-scaling.jpg)                           | **Before**: scaling alarms OK; Service Auto Scaling at 2-4 tasks, target tracking on CPU and memory at 70%                                                                         |
| [scaling/event-1-alarms-in-alarm.jpg](scaling/event-1-alarms-in-alarm.jpg)                                                                                                 | **Event**: `vertical-scale`, `cpu-high` and `at-max-tasks` in ALARM at 09:49:08 UTC                                                                                                |
| [scaling/event-2-composite-alarm-children.jpg](scaling/event-2-composite-alarm-children.jpg)                                                                               | The composite alarm and its child alarms' states                                                                                                                                   |
| [scaling/event-3-composite-history-lambda-invoked.jpg](scaling/event-3-composite-history-lambda-invoked.jpg)                                                               | Alarm history: OK to ALARM, then "Successfully executed action ... taskflow-prod-vertical-scaler"                                                                                  |
| [scaling/event-4-lambda-scaled-1-to-2.jpg](scaling/event-4-lambda-scaled-1-to-2.jpg)                                                                                       | The scaler's log: scaled `taskflow-prod-api:1` to `taskflow-prod-api:2`, `{'cpu': 512, 'memory': 768}`                                                                             |
| [scaling/after-1-task-definition-revisions.jpg](scaling/after-1-task-definition-revisions.jpg), [after-2-task-size-512-768.jpg](scaling/after-2-task-size-512-768.jpg)     | **After**: revision 2 at 512 CPU / 768 MiB                                                                                                                                         |
| [scaling/after-3-rollout-in-progress.jpg](scaling/after-3-rollout-in-progress.jpg), [after-4-rollout-completed.jpg](scaling/after-4-rollout-completed.jpg)                 | The rolling deployment to revision 2, then complete with 0 failed tasks                                                                                                            |
| [scaling/dashboard-during-scaling.jpg](scaling/dashboard-during-scaling.jpg)                                                                                               | The `taskflow-prod` dashboard: requests, CPU, tasks 2 to 4, reserved CPU and memory stepping up                                                                                    |
| [scaling/03-alarm-history.txt](scaling/03-alarm-history.txt) to [10-plan-after-vertical-scale.txt](scaling/10-plan-after-vertical-scale.txt)                               | Raw outputs: alarm history, scaler log, task definitions before and after, service events, metrics, the load test summary, and a Terraform plan showing releases keep the new size |

**What went wrong.** During the rollout the service briefly ran 8 tasks, each allowed 10 database
connections, which reached PostgreSQL's connection limit. For two minutes (09:52-09:54 UTC) the ALB
returned about 2,800 5xx, around 1.5% of the requests in that window; the app logs show `remaining
connection slots are reserved` and `too many clients`. The runbook's "Database connection pool
exhaustion" entry covers it, and the fix is a lower `DB_POOL_MAX`.

## Pipeline (GitLab CI)

| Folder                                                             | Shows                                                                                                                                |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| [ci/mr8-run2-green-through-plan/](ci/mr8-run2-green-through-plan/) | MR !8's pipeline passing lint, security (Trivy, gitleaks), test, build (with the image scan) and plan; `summary.txt` lists every job |
| [ci/mr8-run1-before-variables/](ci/mr8-run1-before-variables/)     | The first run, before the AWS variables existed: plan stops with a clear missing-variable error                                      |

## Still to capture

- The main-branch pipeline: the manual apply gate, configure, deploy and smoke test.
