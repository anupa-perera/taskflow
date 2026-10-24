#!/usr/bin/env bash
# Runs the pinned Terraform image (the same version CI uses) against one stack directory.
# Usage: scripts/terraform.sh <stack-dir> <terraform args...>
#   e.g. scripts/terraform.sh terraform/bootstrap plan
set -euo pipefail

TERRAFORM_IMAGE="hashicorp/terraform:1.17.0"
STACK_DIR="${1:?usage: scripts/terraform.sh <stack-dir> <terraform args...>}"
shift
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

# Never empty, so it expands safely under `set -u` on any bash version.
docker_args=(run --rm)
# Interactive only with a real terminal (apply's "yes" prompt); CI and scripts have none.
if [ -t 0 ]; then docker_args+=(-it); fi
# `-e NAME` without a value copies it from this environment, keeping secrets off the command line.
docker_args+=(
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION
  -v "$(host_path "$repo_root"):/work"
  -w "/work/${STACK_DIR}"
  "$TERRAFORM_IMAGE"
)

MSYS_NO_PATHCONV=1 exec docker "${docker_args[@]}" "$@"
