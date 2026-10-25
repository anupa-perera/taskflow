#!/usr/bin/env bash
# Runs Ansible from the pinned controller image (ansible/Dockerfile), the same one CI uses.
# Usage: scripts/ansible.sh <command> [args...]
#   e.g. scripts/ansible.sh ansible-playbook playbooks/ecs-hosts.yml --diff
set -euo pipefail

IMAGE="taskflow-ansible:local"
PROFILE="${TASKFLOW_AWS_PROFILE:-taskflow}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Docker Desktop on Windows needs C:/... paths; elsewhere paths pass through unchanged.
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
# A separate assignment so `set -e` stops here if the export fails; eval of an empty string would not.
credentials="$(aws configure export-credentials --profile "$PROFILE" --format env)"
eval "$credentials"
AWS_REGION="$(aws configure get region --profile "$PROFILE" || true)"
export AWS_REGION="${AWS_REGION:?profile $PROFILE has no region; run: aws configure set region ap-south-1 --profile $PROFILE}"
# The AWS CLI v1 in the image (used by the drain tasks) reads only AWS_DEFAULT_REGION.
export AWS_DEFAULT_REGION="$AWS_REGION"

# Cached after the first build; rebuilt only when ansible/ dependencies change.
docker build --quiet --tag "$IMAGE" "$(host_path "$repo_root/ansible")" >/dev/null

docker_args=(run --rm)
if [ -t 0 ]; then docker_args+=(-it); fi
docker_args+=(
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION -e AWS_DEFAULT_REGION
  # The Windows mount is world-writable, and Ansible ignores an ansible.cfg found in such a directory.
  -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg
  -v "$(host_path "$repo_root"):/work"
  "$IMAGE"
)

MSYS_NO_PATHCONV=1 exec docker "${docker_args[@]}" "$@"
