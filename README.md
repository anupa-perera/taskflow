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

## Running it locally

Needs Docker, Node.js 24 and Yarn (through Corepack: `corepack enable`).

The whole stack in containers, built the same way as production: PostgreSQL, a one-off migration
as the admin user, then the API as the restricted `taskflow_app` role:

```bash
cd app
docker compose up --build --detach
curl -i http://localhost:3000/health   # once the api container is up
docker compose down
```

The API's OpenAPI documentation is at <http://localhost:3000/docs>.

For development with reload, keep only the database and migration in Docker:

```bash
cd app
docker compose up -d postgres migrate
cp .env.example .env
yarn install
yarn dev
```

Checks the pipeline runs: `yarn lint`, `yarn typecheck`, `yarn test` (at least 70 % coverage) and
`yarn build`.

## Setting up from a clean AWS account

Needs Bash (Git Bash on Windows), the AWS CLI, Docker and Node.js (`scripts/teardown.sh` uses it
to check its plan). Terraform runs in Docker, so it does not need to be installed.

1. **An IAM user for deploying** (not the root user) with permission to create every resource in
   the stack, and an access key in a named profile: `aws configure --profile taskflow`, region
   `ap-south-1`. `scripts/terraform.sh` reads `TASKFLOW_AWS_PROFILE` (default `taskflow`); the
   AWS CLI commands and `scripts/deploy.sh` need it selected in the shell:

   ```bash
   export AWS_PROFILE=taskflow AWS_REGION=ap-south-1
   ```

2. **The Terraform state bucket**, once per account. Its state stays local and git-ignored:

   ```bash
   scripts/terraform.sh terraform/bootstrap init
   scripts/terraform.sh terraform/bootstrap apply
   ```

3. **Point the prod stack at it**:

   ```bash
   scripts/terraform.sh terraform/envs/prod init \
     -backend-config="bucket=$(scripts/terraform.sh terraform/bootstrap output -raw state_bucket </dev/null)" \
     -backend-config="region=ap-south-1"
   ```

4. **Create the image repository first**, because the task definitions need an image to point at:

   ```bash
   tag="$(git rev-parse --short=8 HEAD)"
   scripts/terraform.sh terraform/envs/prod apply -target=module.ecr -var image_tag="$tag"
   ```

5. **Build and push that image**: step 1 of "Deploying a release" in the
   [runbook](docs/runbook.md#deploying-a-release).
6. **Create everything else**, about 15 minutes (RDS is the slow part):

   ```bash
   scripts/terraform.sh terraform/envs/prod apply -var image_tag="$tag"
   ```

7. **Run the first release**, which creates the schema and the `taskflow_app` role: step 3 of
   "Deploying a release". Until it finishes, `/health` passes but `/tasks` returns 500.
8. **Check it** through the ALB:
   `curl -i "http://$(scripts/terraform.sh terraform/envs/prod output -raw alb_dns_name </dev/null)/tasks"`.

   Terraform runs in Docker with a terminal attached when it has one; `</dev/null` inside `$( )`
   keeps that terminal's control characters out of the captured value.

The stack costs about $4/day. `scripts/teardown.sh` removes it and keeps the state bucket.

## Scope and non-goals

In scope: everything the brief requires, plus both bonus items.

| Area               | Decision                                                                                                                           |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Horizontal scaling | ECS Service Auto Scaling (target tracking) scales out first.                                                                       |
| Vertical scaling   | Grows task CPU/memory only when the service is already at its maximum task count and still saturated (CloudWatch composite alarm). |
| Dashboard          | CloudWatch dashboard, defined in Terraform.                                                                                        |
| CI to AWS auth     | Static IAM access keys for a least-privilege CI user, stored as masked and protected GitLab CI/CD variables.                       |
| Source hosting     | GitLab is the primary repository (it runs the pipeline); it push-mirrors to GitHub.                                                |

Deliberate non-goals and future improvements, each a known gap rather than an oversight:

| Non-goal                                               | Why                                                                                                                                                  | What production would do                                                                                                           |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| HTTPS and a custom domain                              | Requires an owned domain.                                                                                                                            | ACM certificate on the ALB, Route 53 alias, HTTP to HTTPS redirect.                                                                |
| Multi-AZ RDS, one NAT gateway per AZ                   | Roughly doubles the cost of both. Each is a single point of failure here.                                                                            | Enable `multi_az` and one NAT gateway per AZ.                                                                                      |
| Additional environments                                | The brief asks for `envs/prod` only.                                                                                                                 | Add `terraform/envs/staging` reusing the same modules.                                                                             |
| API authentication                                     | Internal service per the scenario.                                                                                                                   | OIDC/JWT at the ALB or in the app.                                                                                                 |
| OIDC federation for CI                                 | Static keys chosen for simplicity.                                                                                                                   | GitLab OIDC to a short-lived IAM role, no stored keys.                                                                             |
| Least-privilege CI deploy user                         | Cut for time. `taskflow-ci-deploy` has broad permissions; only protected `main` pipelines receive its keys, and plans use a separate read-only user. | A policy limited to the services and resource prefixes the stack manages, or an OIDC role with that policy.                        |
| Configuring hosts the ASG launches later automatically | Cut for time. Until then, a host added by scaling or replacement is configured by the next pipeline's `configure` stage.                             | An EventBridge rule on the ASG's successful-launch event triggers the configure job for that instance (ADR 0001).                  |
| Node.js runtime security-release check                 | Cut for time. Trivy cannot see the Node binary in the distroless image, so its patch level is not scanned.                                           | A CI job comparing the image's `node --version` with the security releases in nodejs.org's release index, failing on a missed fix. |
| Integration tests against a real database              | Unit tests with a coverage gate meet the brief.                                                                                                      | Postgres service container in CI.                                                                                                  |
| Grafana, WAF, blue/green, image signing                | Beyond the brief.                                                                                                                                    | Add as the service's risk profile demands.                                                                                         |

## DevOps vs. Platform Engineering

DevOps and platform engineering share the same goal. Which is to enable teams to ship reliable
software at high velocity. Both roles are put in place in hopes of reducing the friction between
writing code and running it in production. DevOps is essentially about promoting collaboration and
shared responsibility. While platform engineering is about providing internal tools and services to
enable those DevOps practices.

DevOps helps bring development and operations closer together. The norm has been for developers to
write software and hand it off to ops teams to deploy and maintain. This division often resulted in
delays and misunderstandings. To address this issue, DevOps has been introduced to promote shared
responsibility between teams across the software lifecycle. It's essentially supported by automated
testing, continuous delivery, and monitoring. In this project, the GitLab pipeline tests and scans
every change the same way and deploys from `main` behind a manual approval. The success of DevOps
comes from technical practices and a collaborative culture.

Platform engineering is about establishing internal platforms for developer teams to use within the
company for their day to day workscope. Which helps reduce their repetitive manual work in the form
of workflow automations. A platform team can provide services such as setting up standard deployment
workflows, implementing ready-made infrastructure, and building in monitoring tools. One such example
is developers could launch a service through a self-service portal without configuring each piece of
infrastructure themselves. Here, the reusable Terraform modules (`network`, `database`,
`ecs-cluster`, `ecs-service`) play that role: a new service or a staging environment instantiates
them with different inputs instead of building its infrastructure from scratch. In hindsight, the
platform team sees developers as internal customers and improves on the platform based on their
needs. In the longer run this saves time and helps boost productivity for developer teams.

Essentially these two roles complement each other within an organisation. DevOps helps set the rules
for everyone to collaborate on delivering software solutions, while Platform Engineering provides
re-usable tools to help with this task. An effective platform will make things easier for developers
and preserve their ownership of the apps.

## The shift toward DevSecOps

DevSecOps makes security a shared responsibility across the software development life cycle. From design through development and delivery all the way to operations. It’s not just something tacked on at the end. The well-known part of this process is the "shifting left" concept. That means running security checks early and continuously while responding swiftly once the system is live.

In the past, a security review was done at the very end. A separate team would look over a release and find problems long after the code was already written and was about to deploy. This practice has often led to either stopping the release or letting it go out with known issues. That approach doesn’t work anymore, especially when teams deploy multiple times a day. Present-day AI code generation has made it even more difficult for such manual reviews to keep up. Such late discoveries often add rework, delay releases and leave production systems open for malicious attacks. Furthermore, several well-known vulnerabilities have made shift-left concepts essential for production systems.

First supply chain attacks. These happen when attackers compromise applications through their dependencies, base images or build systems. That means security isn’t about the code your team writes. It’s about everything that goes into the app. Second infrastructure as code. Now a misconfigured storage bucket or a broad IAM policy is just a line in a merge request. That means many risks can be caught before they even become problems. Another issue is leaked credentials. If a password or API key gets committed to Git, it persists there. In the history and in every copy of the code. Just deleting at this point isn’t enough to make the system secure. You have to revoke or rotate it.

Scanners do not replace security engineers. That is why DevSecOps matters. DevSecOps fixes these issues by making security checks automatic, fast and part of the developer workflow. So those security vulnerabilities are identified every time someone makes a change.

This project applies DevSecOps principles at each layer:

- **Code and secrets:** gitleaks scans the whole git history for credentials in the pipeline's
  security stage; `.env` files and Terraform state are git-ignored from the start.
- **Dependencies and images:** Trivy scans the container image and fails the pipeline on HIGH or
  CRITICAL findings. It cannot see the Node.js runtime in a distroless image (ADR 0003); a check
  against Node.js security releases is listed under future improvements.
- **Infrastructure:** Trivy's configuration scanner and tflint review every Terraform change.
  Accepted exceptions are written down with a reason and an expiry date in `.trivyignore.yaml`, so
  risk acceptance is reviewable rather than silent.
- **Runtime design:** a distroless, non-root image with no shell, least-privilege IAM roles, a
  database user that can only read and write application tables, credentials injected from Secrets
  Manager at runtime, TLS enforced by RDS and certificate-verified by the app and an application
  database password sent only as a salted SCRAM verifier.
