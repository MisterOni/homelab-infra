#!/usr/bin/env bash
# Configure CouchDB for the Obsidian "Self-hosted LiveSync" plugin via the
# _config HTTP API. Run once after the couchdb container is up. Idempotent —
# safe to re-run. Reads COUCHDB_USER / COUCHDB_PASSWORD from the stack's .env.
#
#   bash ~/stacks/notes/setup-couchdb.sh
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${COUCHDB_USER:?COUCHDB_USER not set (expected in .env)}"
: "${COUCHDB_PASSWORD:?COUCHDB_PASSWORD not set (expected in .env)}"
HOST="${COUCHDB_HOST:-http://127.0.0.1:5984}"
AUTH=(-s -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}")

echo "Waiting for CouchDB at ${HOST} ..."
until curl "${AUTH[@]}" "${HOST}/_up" >/dev/null 2>&1; do sleep 2; done

put() { curl "${AUTH[@]}" -X PUT "${HOST}/_node/_local/_config/$1" -d "$2" >/dev/null; }

# System databases (single node)
curl "${AUTH[@]}" -X PUT "${HOST}/_users"      >/dev/null || true
curl "${AUTH[@]}" -X PUT "${HOST}/_replicator" >/dev/null || true

# LiveSync-required server settings
put chttpd/require_valid_user       '"true"'
put chttpd_auth/require_valid_user  '"true"'
put chttpd/max_http_request_size    '"4294967296"'
put couchdb/max_document_size       '"50000000"'
put httpd/WWW-Authenticate          '"Basic realm=\"couchdb\""'

# CORS so the Obsidian app (desktop + mobile) can talk to CouchDB
put chttpd/enable_cors  '"true"'
put cors/origins        '"app://obsidian.md,capacitor://localhost,http://localhost"'
put cors/credentials    '"true"'
put cors/methods        '"GET, PUT, POST, HEAD, DELETE"'
put cors/headers        '"accept, authorization, content-type, origin, referer"'

echo "✅ CouchDB configured for Obsidian LiveSync."
