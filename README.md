# TaskFlow

TaskFlow is a small internal task management REST API, and the delivery platform that runs it on AWS:
Terraform provisions the infrastructure, Ansible configures the ECS hosts, and a GitLab CI/CD pipeline
builds, scans, tests and deploys the containerised service to Amazon ECS on EC2.

## Repository layout

```
app/          TaskFlow API (TypeScript + Fastify), unit tests and Dockerfile
terraform/    Infrastructure as code: reusable modules/ and the envs/prod/ root
ansible/      Configuration management for the ECS host instances
docs/         Architecture diagram, operational runbook and ADRs
evidence/     Screenshots proving the system ran
.gitlab-ci.yml
```

## Scope and non-goals

In scope: everything the brief requires, plus both bonus items.

| Area               | Decision                                                                                                                           |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Horizontal scaling | ECS Service Auto Scaling (target tracking) scales out first.                                                                       |
| Vertical scaling   | Grows task CPU/memory only when the service is already at its maximum task count and still saturated (CloudWatch composite alarm). |
| Dashboard          | CloudWatch dashboard, defined in Terraform.                                                                                        |
| CI to AWS auth     | Static IAM access keys for a least-privilege CI user, stored as masked and protected GitLab CI/CD variables.                       |
| Source hosting     | GitLab is the primary repository (it runs the pipeline); it push-mirrors to GitHub.                                                |

Deliberate non-goals, each a known gap rather than an oversight:

| Non-goal                                  | Why                                                                       | What production would do                                            |
| ----------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| HTTPS and a custom domain                 | Requires an owned domain.                                                 | ACM certificate on the ALB, Route 53 alias, HTTP to HTTPS redirect. |
| Multi-AZ RDS, one NAT gateway per AZ      | Roughly doubles the cost of both. Each is a single point of failure here. | Enable `multi_az` and one NAT gateway per AZ.                       |
| Additional environments                   | The brief asks for `envs/prod` only.                                      | Add `terraform/envs/staging` reusing the same modules.              |
| API authentication                        | Internal service per the scenario.                                        | OIDC/JWT at the ALB or in the app.                                  |
| OIDC federation for CI                    | Static keys chosen for simplicity.                                        | GitLab OIDC to a short-lived IAM role, no stored keys.              |
| Integration tests against a real database | Unit tests with a coverage gate meet the brief.                           | Postgres service container in CI.                                   |
| Grafana, WAF, blue/green, image signing   | Beyond the brief.                                                         | Add as the service's risk profile demands.                          |
