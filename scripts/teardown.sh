#!/usr/bin/env bash
# Destroys the prod stack for a pause, including the deletion-protected database, without leaving
# a final snapshot behind. The state bucket (terraform/bootstrap) is kept.
# Usage: scripts/teardown.sh
set -euo pipefail

STACK="terraform/envs/prod"
DB="module.database.aws_db_instance.this"
PLAN_FILE="unlock.tfplan"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# For humans: keeps the terminal, so Terraform can ask for confirmation.
terraform() { "$repo_root/scripts/terraform.sh" "$STACK" "$@"; }
# For parsing: no terminal, so the output is exactly what Terraform printed.
terraform_output() { "$repo_root/scripts/terraform.sh" "$STACK" "$@" </dev/null; }

# The plan holds sensitive values; remove it however the script ends.
trap 'rm -f "$repo_root/$STACK/$PLAN_FILE"' EXIT

# Same values in both steps, so the destroy sees the unlocked, snapshot-free configuration.
# Destroy never uses the image, but image_tag is required; any valid SHA satisfies it.
unlock=(-var database_deletion_protection=false -var database_final_snapshot=false -var image_tag=0000000)

# A separate assignment, so a failed lookup (credentials, backend) stops here instead of
# looking like "no database".
state_entries="$(terraform_output state list)"

if grep -Fqx "$DB" <<<"$state_entries"; then
  echo "Step 1/2: switch off database deletion protection and the final snapshot."
  terraform plan -input=false -target="$DB" "${unlock[@]}" -out="$PLAN_FILE"
  # An unlock may only change settings in place. A create or replace here would build a new
  # database (and its dependencies) just to destroy it.
  # shellcheck disable=SC2016 # The single-quoted program is JavaScript, not shell.
  terraform_output show -json "$PLAN_FILE" | node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
      const allowed = new Set(["update", "no-op", "read"]);
      const unsafe = JSON.parse(raw).resource_changes.filter((c) => !c.change.actions.every((a) => allowed.has(a)));
      for (const c of unsafe) console.error(`refusing: ${c.address} would ${c.change.actions.join("+")}`);
      process.exit(unsafe.length ? 1 : 0);
    });'
  read -r -p "Apply this unlock? [y/N] " answer
  [ "$answer" = "y" ] || { echo "Aborted; nothing changed."; exit 1; }
  terraform apply -input=false "$PLAN_FILE"
else
  echo "No database in state; skipping the unlock step."
fi

echo "Step 2/2: destroy the prod stack."
terraform destroy "${unlock[@]}"
