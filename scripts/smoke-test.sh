#!/usr/bin/env bash
# Checks a release through the ALB: every endpoint must answer 200, or the script fails.
# Usage: scripts/smoke-test.sh <alb-dns-name>   (terraform output alb_dns_name)
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <alb-dns-name>" >&2
  exit 2
fi
alb_dns_name="$1"
ENDPOINTS=(/health /tasks)
REQUEST_TIMEOUT_SECONDS=10
# curl retries only transient failures: timeouts and 5xx such as a 502 while targets register.
RETRIES=5
RETRY_DELAY_SECONDS=5

failed=0
for path in "${ENDPOINTS[@]}"; do
  # A connection failure prints 000 and exits non-zero; the comparison below reports it.
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time "$REQUEST_TIMEOUT_SECONDS" --retry "$RETRIES" --retry-delay "$RETRY_DELAY_SECONDS" \
    "http://${alb_dns_name}${path}" || true)"
  echo "GET ${path}: ${status}"
  if [ "$status" != "200" ]; then failed=1; fi
done
exit "$failed"
