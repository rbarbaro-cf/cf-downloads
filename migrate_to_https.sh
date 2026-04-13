#!/bin/bash

# CloudFirst - One-time migration from FTP/GitHub to HTTPS deployment
# This script is downloaded and run by the existing FTP cf_worker_sync.sh
# It creates the HTTPS credential file, downloads the new sync script,
# and deletes itself when done.

LOG_FILE="/tmp/cf_worker_sync.log"
log() { echo "[$(date +%H:%M:%S)] MIGRATE: $*" | tee -a "$LOG_FILE"; }

log "Starting migration to HTTPS deployment..."

# ---------- Create credential file ----------
CRED_FILE="/etc/cf-deploy.conf"
DEPLOY_URL="https://deploy.dscsvc.com"
DEPLOY_USER="worker"
DEPLOY_PASS="G34rm@n22"

umask 077
cat > "$CRED_FILE" <<EOF
DEPLOY_URL=${DEPLOY_URL}
DEPLOY_USER=${DEPLOY_USER}
DEPLOY_PASS=${DEPLOY_PASS}
EOF
chmod 600 "$CRED_FILE"
log "Credential file created at ${CRED_FILE}"

# ---------- Test HTTPS connectivity ----------
if ! curl -fsSL -u "${DEPLOY_USER}:${DEPLOY_PASS}" -o /dev/null "${DEPLOY_URL}/core/cf_worker_sync.sh" 2>/dev/null; then
  log "ERROR: Cannot reach ${DEPLOY_URL} - migration aborted. FTP sync will continue."
  rm -f "$CRED_FILE"
  exit 1
fi
log "HTTPS connectivity verified"

# ---------- Download new sync script ----------
SYNC_SCRIPT="/usr/local/nagios/libexec/cf_worker_sync.sh"
SYNC_TMP="${SYNC_SCRIPT}.https.tmp"

if curl -fsSL -u "${DEPLOY_USER}:${DEPLOY_PASS}" -o "$SYNC_TMP" "${DEPLOY_URL}/core/cf_worker_sync.sh"; then
  if [[ -s "$SYNC_TMP" ]]; then
    chmod 755 "$SYNC_TMP"
    chown nagios:nagios "$SYNC_TMP"
    mv -f "$SYNC_TMP" "$SYNC_SCRIPT"
    log "New HTTPS sync script installed"
  else
    log "ERROR: Downloaded sync script is empty - keeping old version"
    rm -f "$SYNC_TMP"
    exit 1
  fi
else
  log "ERROR: Failed to download new sync script - keeping old version"
  rm -f "$SYNC_TMP"
  exit 1
fi

# ---------- Clean up GitHub artifacts if present ----------
# Remove deploy key and SSH config created by the GitHub version
if [[ -f /root/.ssh/id_ed25519 ]] && grep -q "cf-workers" /root/.ssh/id_ed25519.pub 2>/dev/null; then
  rm -f /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub
  log "Removed GitHub deploy key"
fi

if [[ -f /root/.ssh/config ]] && grep -q "ssh.github.com" /root/.ssh/config 2>/dev/null; then
  rm -f /root/.ssh/config
  log "Removed GitHub SSH config"
fi

# Remove GitHub env file
if [[ -f /etc/cf-worker.env ]]; then
  rm -f /etc/cf-worker.env
  log "Removed GitHub env file"
fi

# Remove sparse checkout directory
if [[ -d /opt/cf-sync ]]; then
  rm -rf /opt/cf-sync
  log "Removed GitHub sparse checkout directory"
fi

# ---------- Delete this migration script ----------
rm -f /usr/local/nagios/libexec/migrate_to_https.sh
rm -f /tmp/migrate_to_https.sh
log "Migration complete - this script has been deleted"
log "Next sync run will use HTTPS deployment"
