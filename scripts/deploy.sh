#!/usr/bin/env bash
# Releases a version: runs its schema migration, then moves the API service to its revision.
# Both revisions are registered by `terraform apply` (outputs migrate_task_definition_arn and
# api_task_definition_arn). AWS credentials come from the environment or AWS_PROFILE.
# Usage: scripts/deploy.sh <cluster> <service> <migrate-task-definition-arn> <api-task-definition-arn>
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <cluster> <service> <migrate-task-definition-arn> <api-task-definition-arn>" >&2
  exit 2
fi
cluster="$1" service="$2" migrate_task_definition="$3" api_task_definition="$4"
# Covers a host scale-out for the task (a few minutes) plus the migration's own 5-minute timeout.
MIGRATION_DEADLINE_SECONDS="${MIGRATION_DEADLINE_SECONDS:-600}"
POLL_SECONDS=10

# The Windows AWS CLI ends lines with CRLF, which breaks the comparisons below.
aws_text() { aws "$@" --output text | tr -d '\r'; }
# Git Bash would rewrite the SSM parameter name (/taskflow-prod/...) into a Windows path.
export MSYS_NO_PATHCONV=1

# The service's subnets and security group are the only ones that can reach the database.
network="$(aws ecs describe-services --cluster "$cluster" --services "$service" \
  --query 'services[0].networkConfiguration' --output json)"

# Migrations are forward-only; this is the point-in-time restore target if one damages data.
echo "Restore point: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Running the migration: $migrate_task_definition"
run="$(aws_text ecs run-task --cluster "$cluster" --task-definition "$migrate_task_definition" \
  --count 1 --started-by deploy --network-configuration "$network" \
  --query '[tasks[0].taskArn, failures[0].reason]')"
read -r task_arn failure <<<"$run"
if [ "$task_arn" = "None" ]; then
  echo "The migration task did not start: $failure" >&2
  exit 1
fi

# If this script ends first (deadline, Ctrl-C, a cancelled job), stop the migration, so it cannot
# change the database after the deploy has reported failure.
stop_migration() {
  aws ecs stop-task --cluster "$cluster" --task "$task_arn" \
    --reason "deploy.sh ended before the migration finished" >/dev/null || true
}
trap stop_migration EXIT
trap 'exit 1' INT TERM

deadline=$((SECONDS + MIGRATION_DEADLINE_SECONDS))
until [ "$(aws_text ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" \
  --query 'tasks[0].lastStatus')" = "STOPPED" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "The migration did not finish within ${MIGRATION_DEADLINE_SECONDS}s; stopping it." >&2
    exit 1
  fi
  sleep "$POLL_SECONDS"
done
trap - EXIT INT TERM

# Stopped is not success; only the container's exit code says whether the migration worked.
result="$(aws_text ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" \
  --query 'tasks[0].[containers[0].exitCode, stoppedReason]')"
read -r exit_code stopped_reason <<<"$result"
if [ "$exit_code" != "0" ]; then
  echo "The migration failed (exit code $exit_code: $stopped_reason)." >&2
  echo "Logs: stream migrate/migrate/${task_arn##*/} in the task log group." >&2
  exit 1
fi

# Vertical scaling may have resized the service since `terraform apply` registered this revision;
# rolling it out would undo that. Re-running the release registers a revision at the new size.
task_size_parameter="${TASK_SIZE_PARAMETER:-/$cluster/api/task-size}"
recorded_size="$(aws_text ssm get-parameter --name "$task_size_parameter" --query 'Parameter.Value')"
release_size="$(aws_text ecs describe-task-definition --task-definition "$api_task_definition" \
  --query 'taskDefinition.[cpu, memory]')"
read -r release_cpu release_memory <<<"$release_size"
if [ "$recorded_size" != "{\"cpu\":$release_cpu,\"memory\":$release_memory}" ]; then
  echo "The service's size is now $recorded_size, but this revision has cpu $release_cpu and" >&2
  echo "memory $release_memory. Re-run the release to register a revision at the current size." >&2
  exit 1
fi

echo "Rolling out: $api_task_definition"
aws ecs update-service --cluster "$cluster" --service "$service" \
  --task-definition "$api_task_definition" --query 'service.serviceName' --output text >/dev/null
aws ecs wait services-stable --cluster "$cluster" --services "$service"

# A circuit-breaker rollback also ends stable, so check the service runs what was deployed.
# shellcheck disable=SC2016 # JMESPath literals use backticks.
primary="$(aws_text ecs describe-services --cluster "$cluster" --services "$service" \
  --query 'services[0].deployments[?status==`PRIMARY`] | [0].[taskDefinition, rolloutState]')"
read -r running_task_definition rollout_state <<<"$primary"
if [ "$running_task_definition" != "$api_task_definition" ] || [ "$rollout_state" != "COMPLETED" ]; then
  echo "The rollout did not complete: the service runs $running_task_definition ($rollout_state)." >&2
  exit 1
fi
echo "Deployed $api_task_definition"
