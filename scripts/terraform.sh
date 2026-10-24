#!/usr/bin/env bash
# Runs the pinned Terraform image (the same version CI uses) against one stack directory.
# Usage: scripts/terraform.sh <stack-dir> <terraform args...>
#   e.g. scripts/terraform.sh terraform/bootstrap plan
# AWS credentials come from ~/.aws (read-only) using AWS_PROFILE, which defaults to "taskflow"
# so a work profile exported in the shell is never picked up by accident.
set -euo pipefail

TERRAFORM_IMAGE="hashicorp/terraform:1.17.0"
STACK_DIR="${1:?usage: scripts/terraform.sh <stack-dir> <terraform args...>}"
shift

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Docker Desktop on Windows needs C:/... paths; elsewhere paths pass through unchanged.
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Interactive flags only with a real terminal (apply's "yes" prompt); CI and scripts have none.
tty_flags=()
if [ -t 0 ]; then tty_flags=(-it); fi

MSYS_NO_PATHCONV=1 exec docker run --rm "${tty_flags[@]}" \
  -v "$(host_path "$repo_root"):/work" \
  -v "$(host_path "$HOME/.aws"):/root/.aws:ro" \
  -e AWS_PROFILE="${TASKFLOW_AWS_PROFILE:-taskflow}" \
  -w "/work/${STACK_DIR}" \
  "$TERRAFORM_IMAGE" "$@"
