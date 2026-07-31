#!/usr/bin/env bash
# The interview party trick. up: infra→k3s→app→URL. down: leave nothing behind.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  up)
    terraform init -input=false
    time terraform apply -auto-approve
    URL=$(terraform output -raw demo_url)
    echo "waiting for app at $URL ..."
    for _ in {1..60}; do curl -sf "$URL" > /dev/null && break; sleep 10; done
    echo "LIVE → $URL"
    ;;
  down)
    terraform destroy -auto-approve
    echo "all resources destroyed — verify: aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=homelab-demo"
    ;;
  *) echo "usage: demo.sh up|down"; exit 1 ;;
esac
