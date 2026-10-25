# TaskFlow runbook

For whoever is on call. Every command assumes the repository root, Git Bash or a Linux shell, and an
AWS CLI profile for the TaskFlow account (`export AWS_PROFILE=taskflow AWS_REGION=ap-south-1`).
Terraform runs through `scripts/terraform.sh`, which uses the same pinned image as CI.

Names used below:

| Thing                    | Name                                                             |
| ------------------------ | ---------------------------------------------------------------- |
| ECS cluster              | `taskflow-prod`                                                  |
| ECS service              | `taskflow-prod-api`                                              |
| Task definition families | `taskflow-prod-api`, `taskflow-prod-migrate`                     |
| Task logs                | `/taskflow/ecs/taskflow-prod` (streams `api/...`, `migrate/...`) |
| Host logs                | `/taskflow/ec2/taskflow-prod`                                    |
| Database                 | `taskflow-prod` (RDS PostgreSQL 17)                              |
| ECR repository           | `taskflow`                                                       |

Get the ALB address with `scripts/terraform.sh terraform/envs/prod output -raw alb_dns_name`.

## Deploying a release

A release is a commit SHA. Its image is tagged with that SHA, never `latest`.

1. **Build and push** the image (CI does this; by hand, for reference):

   ```bash
   tag="$(git rev-parse --short=8 HEAD)"
   registry="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.ap-south-1.amazonaws.com"
   aws ecr get-login-password | docker login --username AWS --password-stdin "$registry"
   docker build --platform linux/amd64 --provenance=false --sbom=false -t "$registry/taskflow:$tag" app
   docker push "$registry/taskflow:$tag"
   ```

   `--provenance=false --sbom=false` makes the push a single image manifest. Without them Docker
   pushes an image index with attestations, which ECR's scan on push does not scan.

2. **Register the task definitions** for that image. This changes nothing that is running:

   ```bash
   scripts/terraform.sh terraform/envs/prod apply -var image_tag="$tag"
   ```

3. **Migrate, then roll out**:

   ```bash
   out() { scripts/terraform.sh terraform/envs/prod output -raw "$1" </dev/null; }
   scripts/deploy.sh taskflow-prod taskflow-prod-api \
     "$(out migrate_task_definition_arn)" "$(out api_task_definition_arn)"
   ```

   `deploy.sh` prints a **restore point** (UTC time), runs the migration task and requires exit
   code 0, then moves the service to the new revision and waits until it is stable. It fails if the
   service settles on any other revision, which is what a circuit-breaker rollback looks like.

4. **Check** `curl -i http://<alb>/health` and `curl -i http://<alb>/tasks` (the second one
   touches the database; `/health` deliberately does not).

### Schema changes must work with the previous release

Old and new tasks serve traffic together during every rollout, and a rollback runs old code
against the new schema. So migrations are **forward-only and expand/contract**: add tables or
columns in one release; stop reading the old ones; drop them in a later release. Never rename or
drop in the same release that stops using something. (ADR 0002.)

## Rolling back a bad release

A rollback moves the service to an earlier task definition revision. Old revisions stay registered
for this reason. The schema is not rolled back, and the old migration is not run again. An earlier
revision also carries the task size it was registered with; if vertical scaling has resized the
service since, the next release restores the current size.

1. Find the last good revision:

   ```bash
   aws ecs list-task-definitions --family-prefix taskflow-prod-api --sort DESC --max-items 5
   ```

2. Check its image still exists; ECR keeps the 30 most recent images:

   ```bash
   aws ecs describe-task-definition --task-definition taskflow-prod-api:<N> \
     --query 'taskDefinition.containerDefinitions[0].image'
   aws ecr describe-images --repository-name taskflow --image-ids imageTag=<tag from the image>
   ```

   If it has expired, rebuild that commit and push it under the same tag first.

3. Move the service to it and wait:

   ```bash
   aws ecs update-service --cluster taskflow-prod --service taskflow-prod-api \
     --task-definition taskflow-prod-api:<N>
   aws ecs wait services-stable --cluster taskflow-prod --services taskflow-prod-api
   ```

4. Check `/health` and `/tasks`, then make the code match: revert the bad commit on `main`, so the
   next release does not bring it back.

If ECS's deployment circuit breaker already rolled back by itself, the service events say so
(`aws ecs describe-services ... --query 'services[0].events[0:10]'`) and step 3 is not needed.

**Data damaged by a migration** is not fixed by a rollback. Restore the database to the restore
point that `deploy.sh` printed (see below).

## Incidents

### Tasks stuck in PROVISIONING or PENDING

The service wants more tasks than the cluster can place.

1. Read why: `aws ecs describe-services --cluster taskflow-prod --services taskflow-prod-api --query 'services[0].events[0:5].message'`.
2. Match the cause:
   - **"no container instance met all of its requirements"**, with RESOURCE:ENI: each `t3.small`
     fits at most **2 tasks** because of network interfaces (ADR 0001). The capacity provider adds
     hosts up to the ASG maximum of 4. If the ASG is already at 4, the cluster is full: lower the
     desired count or raise `max_size` in `terraform/modules/ecs-cluster`.
   - **RESOURCE:MEMORY or RESOURCE:CPU** where hosts are not full: the task is bigger than one
     host can offer, which no number of hosts fixes. Reduce the task size (`task_cpu`,
     `task_memory_mib`).
   - **Hosts not launching**: check the ASG's activity
     (`aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg> --max-items 5`).
     On a fresh apply, the first launches can fail with "Authentication Failure" while the new
     instance profile propagates; the ASG retries by itself within a few minutes.
3. A host that launched but never joined shows no container instance:
   `aws ecs list-container-instances --cluster taskflow-prod`. Open a shell with
   `aws ssm start-session --target <instance-id>` and read `/var/log/ecs/ecs-agent.log`.

### The ALB returns 502 or 503

- **503**: the target group has no registered targets, so no task is running or all are
  starting. (When targets are registered but all unhealthy, the ALB sends traffic to them anyway.)
  `aws elbv2 describe-target-health --target-group-arn <arn>` shows each target and why it is
  unhealthy. Tasks failing their `/health` check or crashing leave a reason in the newest `api/...`
  log streams in `/taskflow/ecs/taskflow-prod`.
- **502**: a target closed the connection or sent an invalid response. Usually a task crashed
  mid-request or the container stopped without draining. Look for tasks stopping in the service
  events and `stoppedReason`:
  `aws ecs describe-tasks --cluster taskflow-prod --tasks <task-arn> --query 'tasks[0].[stoppedReason,containers[0].exitCode]'`.
  Exit code 137 means SIGKILL: out of memory, or shutdown overran the 30 s stop timeout.
- A burst during a deployment that clears on its own points at draining. A stopping task is first
  deregistered from the ALB (up to 30 s for in-flight requests), then sent SIGTERM. The app then has
  25 s to finish (`SHUTDOWN_TIMEOUT_MS`) before it exits, and ECS kills it after 30 s
  (`stopTimeout`). Look for "shutdown timed out" in the logs.

### Database connection pool exhaustion

Symptoms: requests fail with 500 and the ALB's 5xx count rises, while `/health` stays green (it
does not use the database), so ECS does not restart anything. The RDS `DatabaseConnections` metric
is at or near its ceiling.

Two different causes; the task logs (`/taskflow/ecs/taskflow-prod`, level 50 and above) tell them
apart:

**Too many connections in total.** PostgreSQL refuses new ones: `remaining connection slots are
reserved for roles with ...` or `sorry, too many clients already`. Each task opens up to
`DB_POOL_MAX` connections, so the peak is the task count times `DB_POOL_MAX`. The task count
doubles during a deployment, because new tasks start before old ones stop. On `db.t4g.micro`,
`max_connections` is about 80 minus a few reserved slots.

- **Do not force a new deployment.** It doubles the task count again and makes this worse.
- It ends on its own when a rollout finishes. If it lasts, lower the task count (Scaling,
  "Pause horizontal scaling", then set the minimum) or wait for the rollout.
- Fix it for good: keep maximum tasks x 2 x `DB_POOL_MAX` well below `max_connections`, by lowering
  `DB_POOL_MAX` in the API task definition, lowering the service's `deployment_maximum_percent`, or
  using a larger database instance.

**Slow queries holding connections.** The pool waits for a free client and times out, or queries
are cancelled by `statement_timeout`; connections sit at the pool limit while requests queue.

1. Find the queries in **Performance Insights** (RDS console, database `taskflow-prod`): the top SQL
   and wait events show what is slow or blocked. PostgreSQL also logs statements slower than 1 s in
   `/aws/rds/instance/taskflow-prod/postgresql`. Only the tasks can reach the database; hosts and
   operators have no network path to it.
2. Relieve it by restarting the tasks, which closes their pools and cancels their queries:
   `aws ecs update-service --cluster taskflow-prod --service taskflow-prod-api --force-new-deployment`.
   Then fix the slow query. Scaling out tasks makes this worse, not better.

**A real occurrence** (2026-10-25): a vertical scaling rollout at the maximum of 4 tasks briefly
ran 8 tasks with `DB_POOL_MAX` 10. Connections peaked at 75, the logs showed `remaining connection
slots are reserved` and `too many clients`, and the ALB returned about 2,800 5xx (about 1.5% of
requests) for two minutes until the rollout finished. The fix is a lower `DB_POOL_MAX`, sized so
8 tasks stay well under the limit. The evidence is in `evidence/scaling/`.

## Backup and restore

RDS keeps **7 days** of automated backups, with point-in-time restore to any second between the
earliest and latest restorable times (the latest is usually about 5 minutes behind now). Backups run 19:00-19:30 UTC. A **final snapshot** is taken if the database is deleted
normally; `scripts/teardown.sh` skips it for planned pauses.

**Restore to a point in time** (for example, the restore point `deploy.sh` printed). A restore
always creates a **new** instance; the original is untouched. First check the time is inside the
restorable window, and look up the parameter group, which a restore does not copy:

```bash
aws rds describe-db-instances --db-instance-identifier taskflow-prod \
  --query 'DBInstances[0].[LatestRestorableTime, DBParameterGroups[0].DBParameterGroupName]'
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier taskflow-prod \
  --target-db-instance-identifier taskflow-prod-restore \
  --restore-time 2026-10-25T00:02:46Z \
  --db-subnet-group-name taskflow-prod \
  --vpc-security-group-ids <taskflow-prod-db security group id> \
  --db-parameter-group-name <parameter group from above> \
  --no-publicly-accessible
aws rds wait db-instance-available --db-instance-identifier taskflow-prod-restore
```

Then, usually: **recover the damaged rows** by copying them from the restored instance into the
live one, then delete the restored instance.

**Replacing the live database** with the restored one is a planned change, not an on-call fix:

1. Stop writes: scale the service to 0 tasks.
2. Rename `taskflow-prod` to `taskflow-prod-old`, then the restored instance to `taskflow-prod`
   (the DNS name follows the identifier). Wait for both to be available.
3. Bring Terraform in line before any other apply: back up the state, `terraform state rm` the old
   instance, `terraform import` the new one, and check that the plan shows no replacement.
4. Release code that matches the restored schema, then scale the service back up.

**Test the restore** at least once per quarter by restoring to a temporary instance and running a
read query against it.

## Reproducing the stack from a clean account

See [Setting up from a clean AWS account](../README.md#setting-up-from-a-clean-aws-account) in the
README.

## Pausing and tearing down

`scripts/teardown.sh` destroys the prod stack, including the deletion-protected database, without
a final snapshot. It keeps the Terraform state bucket. It asks before switching off deletion
protection, and refuses if that step would create or replace anything.

## Host configuration (Ansible)

Ansible configures the ECS hosts; Terraform only launches them. Run it from the repository root:

```bash
scripts/ansible.sh ansible-playbook playbooks/ecs-hosts.yml
```

`scripts/ansible.sh` builds the pinned controller image from `ansible/Dockerfile` and uses the
`taskflow` AWS profile. Hosts come from the `aws_ec2` dynamic inventory, by the tags
`Role=ecs-host` and `Name=taskflow-prod-ecs-host`, so hosts the ASG adds or replaces are found
without editing anything. Ansible connects through Session Manager (`amazon.aws.aws_ssm`, moving
files through the S3 bucket `taskflow-prod-ansible-<account id>`); there is no SSH.

A healthy second run reports no changes:

```
i-0854518093b7f805b : ok=31 changed=0 unreachable=0 failed=0 skipped=12 rescued=0 ignored=0
i-0f59f57e73bee85f9 : ok=31 changed=0 unreachable=0 failed=0 skipped=12 rescued=0 ignored=0
```

The roles run one host at a time (`serial: 1`), in this order:

| Role               | Manages                                                                                                                           |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `hardening`        | dnf-automatic security updates, an sshd drop-in (no passwords, no root login), the host firewall                                  |
| `ecs_agent`        | Keys in `/etc/ecs/ecs.config` (IMDS blocked for tasks, no privileged containers, image pull and cleanup settings)                 |
| `docker`           | `/etc/docker/daemon.json` log rotation                                                                                            |
| `cloudwatch_agent` | Host memory and disk metrics (namespace `TaskFlow/ECSHosts`); ECS agent, init, audit and dnf logs (`/taskflow/ec2/taskflow-prod`) |

### What a run changes, and how to force one

Each host keeps `/var/lib/taskflow/<name>.applied` (for `docker-daemon`, `ecs-agent`,
`cloudwatch-agent`, `sshd` and `host-firewall`), holding the checksum of the configuration last
applied successfully. A run applies a configuration only when it differs from that checksum.
Delete a marker to force that piece to be applied again on the next run.

### The drained Docker restart

Restarting Docker stops every container on the host, so a `daemon.json` change first drains the
host: its tasks move to other hosts, the run waits for its containers to stop, restarts Docker,
waits for the ECS agent to reconnect, then returns the host to ACTIVE. During the first run, the
API answered 773 of 773 health checks through the ALB while each host was drained and restarted.

- A host that is **already DRAINING** (an instance refresh, or an operator) fails the run on
  purpose: "not ACTIVE; rerun once it is back in service". Rerun it later.
- A run that **dies mid-drain** is finished by the next run: `/var/lib/taskflow/docker-drain.owned`
  records a drain the role started, and the next run returns that host to service. A drain the role
  does not own is left alone.

### Host firewall

The unit `taskflow-host-firewall.service` loads `/etc/nftables/taskflow-host.nft`, the table
`inet taskflow_host`. It drops inbound traffic except loopback, established connections, the
container bridges `docker0` and `ecs-bridge` (task metadata and credentials), ICMP and DHCP.

- **Never run `systemctl restart nftables` or `nft flush ruleset`.** Both delete every table,
  including the rules Docker and the ECS agent rely on, which breaks task metadata and credentials
  on that host. To recover, replace the host (terminate it; the ASG launches another) or do a
  drained Docker restart.
- To rule the firewall out while debugging, `systemctl stop taskflow-host-firewall` removes only
  this table. The next playbook run restores it.

### Security updates

`dnf-automatic` installs security updates daily from the AL2023 release pinned in
`ansible/inventories/prod/group_vars/ecs_hosts.yml` (`al2023_release`). AL2023 repositories are
locked per release, so new fixes arrive by bumping that value through an MR after reading the
release notes. Docker, containerd, runc, ecs-init and the kernel are excluded, because upgrading
them restarts every task or needs a reboot. They arrive with a new ECS-optimized AMI through the
ASG instance refresh, which drains each host first.

### Known gap

A host the ASG launches later serves tasks before it is configured; the next pipeline or playbook
run configures it. An EventBridge trigger on each launch is planned (ADR 0001, README non-goals).

## Scaling

The service scales in two ways. **Horizontal** scaling adds tasks; it is the normal response to
more traffic. **Vertical** scaling gives every task more CPU and memory, and only fires once
horizontal scaling has run out of room.

|              | Horizontal                                       | Vertical                                                                                                   |
| ------------ | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Changes      | Task count, 2 to 4                               | Task size: 256/512, then 512/768, then 1024/896 (CPU units / MiB)                                          |
| Triggered by | Target tracking: average CPU or memory above 70% | Composite alarm `taskflow-prod-api-vertical-scale`                                                         |
| Speed        | Minutes; scale-out cooldown 60 s, scale-in 300 s | A full rolling deployment                                                                                  |
| Direction    | Out and in, automatically                        | Up only; scaling down is a manual decision                                                                 |
| Use it for   | More traffic                                     | 4 tasks still saturated, or per-task load (heavy requests, memory per request) that more copies do not fix |

New tasks need room on hosts. The capacity provider adds hosts (up to 4 `t3.small`), and each host
fits 2 tasks.

### How vertical scaling decides

The composite alarm `taskflow-prod-api-vertical-scale` goes into ALARM when
(`taskflow-prod-api-cpu-high` **or** `taskflow-prod-api-memory-high`) **and**
`taskflow-prod-api-at-max-tasks`:

- `cpu-high` / `memory-high`: the service's average CPU or memory above 80% for 5 consecutive minutes.
- `at-max-tasks`: the desired task count at 4 for 5 consecutive minutes, so added tasks get time to
  help before tasks are resized.

These three alarms have no actions of their own; only the composite one acts. The target tracking
alarms whose names end in `AlarmLow` sit in ALARM whenever load is low. That is normal: they would
scale in, but the service is already at its minimum.

### How vertical scaling applies a size

The composite alarm invokes the Lambda function `taskflow-prod-vertical-scaler`, once per episode
(on the transition into ALARM). It:

1. Waits if a deployment is in progress (it resets `at-max-tasks`, so the composite alarm fires
   again about a minute later while the load lasts).
2. Picks the next size on the ladder. At the top (1024/896) it logs that and does nothing.
3. Registers a copy of the running task definition at that size: same image, environment and
   secrets.
4. Writes the size to the SSM parameter `/taskflow-prod/api/task-size`, for example
   `{"cpu":512,"memory":768}`.
5. Updates the service, which rolls the new size out like any release: new tasks start before old
   ones stop, and the circuit breaker rolls back a failed rollout.

Terraform builds the task size from that SSM parameter, so the next release keeps the new size.
`scripts/deploy.sh` checks the same parameter and refuses to roll out a revision of a different
size ("The service's size is now ..."): that release was registered before a resize. Re-run the
release.

After an event the service keeps the larger size, because vertical scaling only goes up, while
horizontal scaling returns it to 2 tasks over the next 15-20 minutes.

Every ladder size fits two tasks per `t3.small`, so a rollout can always place new tasks beside
the old ones. 1024 CPU units is one vCPU, all a single Node.js process can use; going further
needs a larger instance type (ADR 0001).

### Watching it

- Dashboard `taskflow-prod`: ALB requests, 5xx and latency (p50, p99); API CPU and memory; running
  and desired tasks and the host count; reserved CPU and memory, which step with each vertical
  event; RDS CPU and connections; host memory and disk.
- Current size: `aws ssm get-parameter --name /taskflow-prod/api/task-size --query Parameter.Value`.
- Why vertical scaling did or did not act: the Lambda's logs in
  `/aws/lambda/taskflow-prod-vertical-scaler`, and
  `aws cloudwatch describe-alarm-history --alarm-name taskflow-prod-api-vertical-scale`.

In Git Bash, prefix commands that pass `/taskflow-prod/...` names with `MSYS_NO_PATHCONV=1`, or Git
Bash rewrites them as Windows paths.

### Intervening

| To                                         | Run                                                                                                                                                                                                                                                                                            |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pause vertical scaling                     | `aws cloudwatch disable-alarm-actions --alarm-names taskflow-prod-api-vertical-scale` (resume with `enable-alarm-actions`)                                                                                                                                                                     |
| Pause horizontal scaling                   | `aws application-autoscaling register-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount --resource-id service/taskflow-prod/taskflow-prod-api --suspended-state DynamicScalingInSuspended=true,DynamicScalingOutSuspended=true` (resume with both `false`) |
| Step up now, without waiting for the alarm | `aws lambda invoke --function-name taskflow-prod-vertical-scaler out.json`                                                                                                                                                                                                                     |
| Scale back down, or set a size             | `aws ssm put-parameter --name /taskflow-prod/api/task-size --value '{"cpu":256,"memory":512}' --overwrite`, then run a release (Deploying a release, steps 2 and 3). Use a size from the ladder.                                                                                               |
| Change thresholds or the ladder            | The locals in `terraform/modules/service/horizontal-scaling.tf` and `vertical-scaling.tf`, then apply                                                                                                                                                                                          |

### Signs it is misbehaving

- **Flapping**: the composite alarm's history shows ALARM and OK every minute, and the Lambda logs
  "Deferred: a deployment is in progress" for more than about 15 minutes. A deployment is stuck:
  read the service events and the circuit breaker's result, and pause vertical scaling while you fix
  it.
- **Stuck at the top**: `at-max-tasks` and `cpu-high` stay in ALARM, and the Lambda logs that the
  service already runs the largest size. Scaling settings cannot fix this; it needs a larger
  instance type with a longer ladder, or a faster application.
- **Desired 4 but fewer running**, or tasks in PROVISIONING or PENDING: host capacity, not task size.
  Vertical scaling will not help; see "Tasks stuck in PROVISIONING or PENDING".
- **The SSM size is larger than the running task's size**: the circuit breaker rolled a step back
  (the service events say why). The next release tries that size again unless you reset the
  parameter.

### Do not

- **Change the task size or count in the ECS console.** The size bypasses the SSM parameter, so the
  next release reverts it; Service Auto Scaling overrides a hand-set count. Change the parameter,
  or the minimum and maximum.
- **Set the SSM parameter above 1024 CPU units or about 950 MiB.** Two tasks no longer fit per host,
  so a rollout can stall with tasks that cannot be placed.
- **Delete the SSM parameter.** Terraform recreates it at the smallest size, and the next release
  shrinks every task.
- **Raise the maximum task count above 4** without raising the ASG maximum: each host fits 2 tasks,
  and a deployment needs room for a second set.
- **Run `terraform apply` from two places at once.** Both use the one prod state, and the state
  lock makes the second wait or fail.

### Known limits

- A release whose service update lands in the instant between the Lambda's deployment check and its
  own update can be replaced by the Lambda's copy: the old image at the new size. The next release
  corrects it; closing the gap fully needs a lock shared by both.

## The pipeline

`.gitlab-ci.yml` runs these stages in order; a failure stops everything after it.

| Stage      | Job                                                        | Gates on                                                                                                                                                        |
| ---------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| lint       | `terraform-validate`, `tflint`, `ansible-lint`, `app-lint` | Formatting, Terraform validity, tflint rules, ansible-lint's production profile, the app's lint, format and type checks                                         |
| security   | `trivy-config`                                             | No HIGH or CRITICAL misconfiguration, except the expiring exceptions in `.trivyignore.yaml`                                                                     |
| security   | `gitleaks`                                                 | No secrets anywhere in the git history                                                                                                                          |
| test       | `test`                                                     | Unit tests pass with at least 70% coverage                                                                                                                      |
| build      | `build`                                                    | The image builds and its Trivy scan has no HIGH or CRITICAL finding, before anything is pushed. On `main` it pushes the image, tagged with the short commit SHA |
| plan       | `plan`                                                     | `terraform plan` with a read-only identity; the saved plan is an artifact, and an MR also gets it as a comment                                                  |
| apply      | `apply`                                                    | **A person clicks it.** Only on `main`, which is protected. It applies exactly the saved plan                                                                   |
| configure  | `configure`                                                | The Ansible playbook against every ECS host (see Host configuration)                                                                                            |
| deploy     | `deploy`                                                   | `scripts/deploy.sh`: the migration, then the rollout (see Deploying a release)                                                                                  |
| smoke-test | `smoke-test`                                               | `GET /health` and `GET /tasks` through the ALB return 200                                                                                                       |

Merge request pipelines run lint through plan and never apply. On `main`, everything runs, and
the pipeline waits at `apply` for a person; configure, deploy and smoke-test then run by
themselves. `apply`, `configure` and `deploy` share a GitLab resource group, so two pipelines never
run them at the same time.

### The manual apply

Read the plan before clicking `apply`, in the plan job's log or the MR comment. If it destroys
something you did not expect, do not apply. A common cause is `main` missing a change that was
already applied to prod.

If someone applied after the plan was made, `apply` fails with "Saved plan is stale". Run a new
pipeline on `main` and apply its plan.

### CI/CD variables

All are masked. Only pipelines on the protected `main` branch receive the deploy credentials.

| Variable                                               | Protected | Purpose                                                                                                    |
| ------------------------------------------------------ | --------- | ---------------------------------------------------------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`           | Yes       | The IAM user `taskflow-ci-deploy`, used by apply, configure and deploy                                     |
| `PLAN_AWS_ACCESS_KEY_ID`, `PLAN_AWS_SECRET_ACCESS_KEY` | No        | The IAM user `taskflow-ci-plan`: read-only, plus reading the app's database secret that the plan refreshes |
| `AWS_ACCOUNT_ID`                                       | No        | Keeps the account ID out of the repository                                                                 |
| `GITLAB_API_TOKEN`                                     | No        | A short-lived token that posts the plan as an MR comment                                                   |

The plan credentials are unprotected so that merge request pipelines can plan; they cannot change
anything. Keep it that way: protecting them stops MR plans, and unprotecting the deploy keys would
hand them to every branch.

### When a job fails

Retry a failed job from its page. `deploy` and `smoke-test` can be retried on their own; they read
the `apply` job's outputs.

| Failure                                                                               | Meaning and next step                                                                                                             |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| A lint job fails while downloading (for example `HTTP Error 500` from Ansible Galaxy) | The download source was briefly unavailable. Retry the job                                                                        |
| `deploy` fails at the migration                                                       | The service was not touched. Read the stream `migrate/migrate/<task id>` in `/taskflow/ecs/taskflow-prod`, fix, and release again |
| `deploy` fails after the rollout                                                      | The circuit breaker rolled back; the job says which revision runs. See Rolling back a bad release                                 |
| `deploy` says "A newer apply registered ..."                                          | Two pipelines overlapped; the newer one deploys. Nothing to do                                                                    |
| `deploy` says "The service's size is now ..."                                         | Vertical scaling resized the service after this plan. Run a new pipeline                                                          |
| `smoke-test` fails                                                                    | Check target health, the service events and the task logs, then roll back if the new revision is bad                              |

Re-running an old pipeline's `deploy` is refused on purpose. Roll back with the steps in Rolling
back a bad release, not with an old pipeline or an old migration.

### Do not

- **Apply while `main` lacks something already applied to prod.** The plan destroys it.
- **Run `terraform apply` locally while a pipeline's `apply` is waiting.** Its plan goes stale, or
  the two race.

The deploy user still has broad permissions; narrowing it is listed in the README's non-goals.
