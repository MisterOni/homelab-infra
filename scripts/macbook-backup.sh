#!/usr/bin/env bash
# =============================================================================
# macbook-backup.sh — Phase 0 one-shot backup of everything on the MacBook.
# Run BEFORE any migration work. Safe to re-run; each run gets its own folder.
# Review the CONFIG block, then:  sudo bash scripts/macbook-backup.sh
# =============================================================================
set -euo pipefail

# ---- CONFIG — adjust paths to your actual install locations ----------------
DEST="${BACKUP_DEST:-/mnt/backup/macbook-migration}"   # where archives land
GITLAB_CONTAINER="gitlab"                              # docker container name
JENKINS_HOME="/var/jenkins_home"                       # or docker volume path
NGINX_CONF_DIR="/etc/nginx"
COMPOSE_DIRS=("/opt/stacks")                           # dirs holding compose files
GRAFANA_URL="http://localhost:3000"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"                     # service-account token, export before running
# -----------------------------------------------------------------------------

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/$STAMP"
mkdir -p "$OUT"
log() { echo "[$(date +%T)] $*"; }

log "1/5 GitLab application backup (this can take a while)..."
docker exec "$GITLAB_CONTAINER" gitlab-backup create STRATEGY=copy
docker cp "$GITLAB_CONTAINER":/var/opt/gitlab/backups "$OUT/gitlab-backups"
# The backup is USELESS without these two files:
docker cp "$GITLAB_CONTAINER":/etc/gitlab/gitlab-secrets.json "$OUT/"
docker cp "$GITLAB_CONTAINER":/etc/gitlab/gitlab.rb "$OUT/"
docker exec "$GITLAB_CONTAINER" gitlab-rake gitlab:env:info > "$OUT/gitlab-version.txt" 2>/dev/null || true

log "2/5 Jenkins home..."
tar czf "$OUT/jenkins-home.tar.gz" -C "$(dirname "$JENKINS_HOME")" "$(basename "$JENKINS_HOME")"

log "3/5 Grafana dashboards (as JSON — these go INTO the git repo)..."
mkdir -p "$OUT/grafana-dashboards"
if [ -n "$GRAFANA_TOKEN" ]; then
  for uid in $(curl -sf -H "Authorization: Bearer $GRAFANA_TOKEN" \
      "$GRAFANA_URL/api/search?type=dash-db" | python3 -c 'import sys,json;[print(d["uid"]) for d in json.load(sys.stdin)]'); do
    curl -sf -H "Authorization: Bearer $GRAFANA_TOKEN" \
      "$GRAFANA_URL/api/dashboards/uid/$uid" > "$OUT/grafana-dashboards/$uid.json"
  done
else
  log "  !! GRAFANA_TOKEN not set — skipping dashboard export. Create a service account token and re-run."
fi

log "4/5 Nginx + compose configs (these also go INTO the git repo)..."
tar czf "$OUT/nginx-conf.tar.gz" "$NGINX_CONF_DIR" 2>/dev/null || log "  !! nginx dir not found, adjust NGINX_CONF_DIR"
for d in "${COMPOSE_DIRS[@]}"; do
  [ -d "$d" ] && tar czf "$OUT/compose-$(basename "$d").tar.gz" "$d"
done

log "5/5 Verify — test-extract every archive (an unverified backup is a hope, not a backup)..."
for f in "$OUT"/*.tar.gz; do
  tar tzf "$f" > /dev/null && log "  OK: $(basename "$f")" || { log "  CORRUPT: $f"; exit 1; }
done

log "DONE → $OUT"
log "NOW: copy $OUT to a second location (external disk or cloud) before travelling."
