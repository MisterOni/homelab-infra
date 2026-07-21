#!/usr/bin/env bash
# Regenerate the redacted PUBLIC journal from the PRIVATE master, then stage it
# into the public homelab-infra repo. Edit ONLY private/JOURNAL.md — never the
# public copy by hand.
set -euo pipefail

JOURNAL_DIR="${JOURNAL_DIR:-$HOME/homelab-notes}"
PUBLIC_REPO="${PUBLIC_REPO:-$HOME/homelab-infra}"

PRIV="$JOURNAL_DIR/private/JOURNAL.md"
PUB="$JOURNAL_DIR/public/JOURNAL.md"

# --- Redaction rules — add your own sensitive strings here -------------------
redact() {
  sed -e 's/chooys\.com/your-domain.example/g' \
      -e 's/jchoo\.me/your-mail.example/g'
      # e.g. add:  -e 's/YOUR-REAL-PUBLIC-IP/<public-ip>/g'
}
# -----------------------------------------------------------------------------

[ -f "$PRIV" ] || { echo "ERROR: private journal not found at $PRIV"; exit 1; }

redact < "$PRIV" > "$PUB"

# Safety net: refuse to publish if a known-sensitive token slipped through.
if grep -nE 'root@pam!terraform=[^<]|chooys\.com|jchoo\.me|BEGIN OPENSSH PRIVATE KEY' "$PUB"; then
  echo "!! Sensitive content still present in public copy — NOT copying to repo."
  exit 1
fi

if [ -d "$PUBLIC_REPO/docs" ]; then
  cp "$PUB" "$PUBLIC_REPO/docs/JOURNAL.md"
  echo "OK: public journal regenerated and copied to $PUBLIC_REPO/docs/JOURNAL.md"
  echo "Review, then: cd $PUBLIC_REPO && git add docs/JOURNAL.md && git commit && git push"
else
  echo "OK: public journal regenerated at $PUB (public repo not found at $PUBLIC_REPO)"
fi
