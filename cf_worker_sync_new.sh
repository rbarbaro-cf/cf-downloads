#!/bin/bash

# CloudFirst worker sync script version 2.30
# created by Rich Barbaro @ CF
# HTTPS deployment edition - uses deploy.dscsvc.com

# Change Log
# 1.01 - added remove files in worker folder to account for cfg file deletions
# 1.10 - added sync for cf_worker_sync.sh
# 1.20 - 5/31/24 - changed sync to use get_service.sh for auto config
# 1.21 - 10/3/24 - added python check and fix
# 1.30 - 2/24/25 - added CustomSQL.xml sync
# 1.40 - 3/18/25 - changed worker sync update to use wget mirror
# 1.50 - 4/25/25 - added update plugins call
# 1.51 - 5/15/25 - removed plugin calls, added mirror to service check scripts
# 2.00 - 3/26/26 - RB
#        - migrated all downloads to HTTPS (deploy.dscsvc.com)
#        - removed FTP and GitHub dependencies
#        - credentials sourced from /etc/cf-deploy.conf
#        - commands/ and templates/ synced via tar archives
#        - safe download pattern: download to temp, verify, then replace
#        - validate nagios config before restarting
# 2.10 - 3/26/26 - RB
#        - added NRDP passive check result (cf_worker_sync_status)
#        - error counter tracks download/extract/validation failures
#        - sends OK or CRITICAL to NagiosXI on each sync run
# 2.20 - 3/27/26 - RB
#        - added -v verbose flag for screen output
#        - improved logging around hosts.cfg and services.cfg generation
# 2.30 - 4/14/26 - RB
#        - added checksum-based change detection: only reload nagios when
#          config files actually change during sync
#        - changed systemctl restart to systemctl reload to preserve
#          check scheduling and prevent check storm on 369+ services
#        - eliminates unnecessary hourly load spikes across worker fleet

# ---------- Strict mode ----------
set -Eeuo pipefail

# ---------- Verbose flag ----------
VERBOSE=false
if [[ "${1:-}" == "-v" ]]; then
  VERBOSE=true
fi

# ---------- Variables ----------
NDIR="/usr/local/nagios/etc/"
LDIR="/usr/local/nagios/etc/objects/"
LIBEXEC="/usr/local/nagios/libexec"
LOG_FILE="/tmp/cf_worker_sync.log"
WNAME=$(hostname -f)
IP=$(hostname -I | awk '{print $1}')
CRED_FILE="/etc/cf-deploy.conf"
NRDP_URL="https://nms.dscsvc.com/nrdp"
NRDP_TOKEN="aAM4sawUGBKMDyVBoKcHvYyBDusntkGbYqu3"
SYNC_ERRORS=0
CHECKSUM_BEFORE="/tmp/cf_sync_checksum_before.md5"
CHECKSUM_AFTER="/tmp/cf_sync_checksum_after.md5"

# ---------- Source credentials ----------
if [[ ! -f "$CRED_FILE" ]]; then
  echo "ERROR: $CRED_FILE not found. Run coreinstall.sh first."
  exit 1
fi
. "$CRED_FILE"

# ---------- Logging ----------
: > "$LOG_FILE"
log() {
  echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"
  if $VERBOSE; then echo "[$(date +%H:%M:%S)] $*"; fi
}

# ---------- Checksum function ----------
# Captures md5sums of all nagios config files for change detection
snapshot_configs() {
  local outfile="$1"
  find "${NDIR}" -type f \( -name "*.cfg" -o -name "*.xml" \) -exec md5sum {} + 2>/dev/null | sort > "$outfile"
}

# ---------- Safe download function ----------
# Downloads to a temp file first. Only returns success if file downloaded OK.
# Usage: safe_fetch <remote_path> <local_dest> [owner] [mode]
safe_fetch() {
  local src="$1" dst="$2" owner="${3:-}" mode="${4:-644}"
  local tmp="${dst}.tmp.$$"

  if curl -fsSL -u "${DEPLOY_USER}:${DEPLOY_PASS}" -o "$tmp" "${DEPLOY_URL}/${src}"; then
    if [[ -s "$tmp" ]]; then
      chmod "$mode" "$tmp"
      [[ -n "$owner" ]] && chown "$owner" "$tmp"
      mv -f "$tmp" "$dst"
      log "       $dst updated"
      return 0
    else
      rm -f "$tmp"
      log "       WARNING: empty download for $src, keeping existing $dst"
      SYNC_ERRORS=$((SYNC_ERRORS + 1))
      return 1
    fi
  else
    rm -f "$tmp"
    log "       WARNING: download failed for $src, keeping existing $dst"
    SYNC_ERRORS=$((SYNC_ERRORS + 1))
    return 1
  fi
}

# ---------- Safe tar sync function ----------
# Downloads a tar.gz, extracts to temp, verifies, then replaces destination.
# Usage: safe_tar_sync <remote_tar_path> <dest_dir> [owner]
safe_tar_sync() {
  local src="$1" dest="$2" owner="${3:-}"
  local tmp_tar="/tmp/sync_tar_$$.tar.gz"
  local tmp_dir="/tmp/sync_extract_$$"

  # Download tar to temp
  if ! curl -fsSL -u "${DEPLOY_USER}:${DEPLOY_PASS}" -o "$tmp_tar" "${DEPLOY_URL}/${src}"; then
    rm -f "$tmp_tar"
    log "       WARNING: download failed for $src, keeping existing $dest"
    SYNC_ERRORS=$((SYNC_ERRORS + 1))
    return 1
  fi

  # Verify tar is not empty and is valid
  if [[ ! -s "$tmp_tar" ]]; then
    rm -f "$tmp_tar"
    log "       WARNING: empty tar for $src, keeping existing $dest"
    SYNC_ERRORS=$((SYNC_ERRORS + 1))
    return 1
  fi

  # Extract to temp directory
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  if ! tar xzf "$tmp_tar" -C "$tmp_dir" 2>>"$LOG_FILE"; then
    rm -f "$tmp_tar"
    rm -rf "$tmp_dir"
    log "       WARNING: tar extraction failed for $src, keeping existing $dest"
    SYNC_ERRORS=$((SYNC_ERRORS + 1))
    return 1
  fi

  # Verify extraction produced files
  if [[ -z "$(ls -A "$tmp_dir" 2>/dev/null)" ]]; then
    rm -f "$tmp_tar"
    rm -rf "$tmp_dir"
    log "       WARNING: tar was empty for $src, keeping existing $dest"
    SYNC_ERRORS=$((SYNC_ERRORS + 1))
    return 1
  fi

  # Everything verified - now wipe destination and move new files in
  mkdir -p "$dest"
  rm -rf "${dest:?}"/*
  mv "$tmp_dir"/* "$dest"/
  [[ -n "$owner" ]] && chown -R "$owner" "$dest"

  # Cleanup
  rm -f "$tmp_tar"
  rm -rf "$tmp_dir"
  log "       $dest synced from $src"
  return 0
}

# ==========================================================================
# BEGIN SYNC
# ==========================================================================
log "**********************************"
log "CloudFirst Worker Sync is starting..."
log "version 2.30 - for Oracle Linux"
log "Worker: $WNAME"
log "IP: $IP"
log "**********************************"
log ""

# ---------- Ensure local directories exist ----------
mkdir -p "${LDIR}worker" "${LDIR}commands" "${LDIR}templates" "$LIBEXEC"
log "       directories verified"

# ---------- Snapshot config checksums BEFORE sync ----------
snapshot_configs "$CHECKSUM_BEFORE"
log "       config checksums captured (before sync)"

# ---------- Python symlink check ----------
if [[ ! -x /usr/bin/python && -x /usr/bin/python3 ]]; then
  ln -sf /usr/bin/python3 /usr/bin/python
  log "       python symlink created"
else
  log "       python OK"
fi

# ---------- Sync get_services.sh and api.sh ----------
log "-----  syncing core scripts  -----"
safe_fetch "core/get_services.sh" "$LIBEXEC/get_services.sh" "nagios:nagios" "755" || true
safe_fetch "core/api.sh" "$LIBEXEC/api.sh" "nagios:nagios" "755" || true

# ---------- Sync CustomSQL.xml ----------
log "-----  syncing CustomSQL.xml  -----"
safe_fetch "iseries/CustomSQL.xml" "${LDIR}CustomSQL.xml" "apache:nagios" "755" || true

# ---------- Sync nagios.cfg ----------
log "-----  syncing nagios.cfg  -----"
# Backup current before overwriting
if [[ -f "${NDIR}nagios.cfg" ]]; then
  cp -f "${NDIR}nagios.cfg" "${NDIR}nagios.cfg-old"
fi
safe_fetch "core/nagios/nagios.cfg" "${NDIR}nagios.cfg" "nagios:nagios" "644" || true

# ---------- Sync commands/ directory (tar) ----------
log "-----  syncing commands directory  -----"
safe_tar_sync "core/commands.tar.gz" "${LDIR}commands" "nagios:nagios" || true

# ---------- Sync templates/ directory (tar) ----------
log "-----  syncing templates directory  -----"
safe_tar_sync "core/templates.tar.gz" "${LDIR}templates" "nagios:nagios" || true

# ---------- Sync and patch localhost.cfg (after templates sync) ----------
log "-----  syncing localhost.cfg  -----"
LOCALHOST_FILE="${LDIR}templates/localhost.cfg"
if safe_fetch "core/localhost.cfg" "$LOCALHOST_FILE" "nagios:nagios" "644"; then
  sed -i "s/localhost/$WNAME/" "$LOCALHOST_FILE"
  sed -i "s/127.0.0.1/$IP/" "$LOCALHOST_FILE"
  log "       localhost.cfg patched with $WNAME / $IP"
fi

# ---------- Generate worker configs ----------
log "-----  generating worker configs  -----"
if [[ -x "$LIBEXEC/get_services.sh" ]]; then
  log "       generating hosts.cfg..."
  "$LIBEXEC/get_services.sh" -g "$WNAME" -h > "${LDIR}worker/hosts.cfg" 2>>"$LOG_FILE" || true
  log "       generating services.cfg..."
  "$LIBEXEC/get_services.sh" -g "$WNAME" -s > "${LDIR}worker/services.cfg" 2>>"$LOG_FILE" || true
  chown -R nagios:nagios "${LDIR}worker"
  log "       worker configs generated"
else
  log "       WARNING: get_services.sh not found, skipping worker config generation"
fi

# ---------- Self-update ----------
log "-----  syncing sync scripts  -----"
safe_fetch "core/cf_worker_sync.sh" "$LIBEXEC/cf_worker_sync.sh" "nagios:nagios" "755" || true
safe_fetch "core/cf_check_host_all.sh" "$LIBEXEC/cf_check_host_all.sh" "nagios:nagios" "755" || true
safe_fetch "core/cf_check_service.sh" "$LIBEXEC/cf_check_service.sh" "nagios:nagios" "755" || true

# ---------- Snapshot config checksums AFTER sync ----------
snapshot_configs "$CHECKSUM_AFTER"
log "       config checksums captured (after sync)"

# ---------- Compare and conditionally reload nagios ----------
if ! diff -q "$CHECKSUM_BEFORE" "$CHECKSUM_AFTER" > /dev/null 2>&1; then
  log "-----  config changes detected - validating and reloading nagios  -----"
  # Log which files changed
  diff "$CHECKSUM_BEFORE" "$CHECKSUM_AFTER" >> "$LOG_FILE" 2>&1 || true
  if /usr/local/nagios/bin/nagios -v "${NDIR}nagios.cfg" >> "$LOG_FILE" 2>&1; then
    systemctl reload nagios
    log "       nagios reloaded successfully"
  else
    log "       WARNING: nagios config validation failed, NOT reloading"
    log "       check ${NDIR}nagios.cfg and $LOG_FILE for errors"
    SYNC_ERRORS=$((SYNC_ERRORS + 1))
  fi
else
  log "-----  no config changes detected - skipping nagios reload  -----"
fi

# ---------- Cleanup checksum files ----------
rm -f "$CHECKSUM_BEFORE" "$CHECKSUM_AFTER"

# ---------- Send NRDP check result ----------
if [[ $SYNC_ERRORS -eq 0 ]]; then
  NRDP_STATE=0
  NRDP_OUTPUT="OK - Worker sync completed successfully"
else
  NRDP_STATE=2
  NRDP_OUTPUT="CRITICAL - Worker sync completed with ${SYNC_ERRORS} error(s). Check ${LOG_FILE}"
fi

/usr/local/nrdp/clients/send_nrdp.sh -u "${NRDP_URL}" -t "${NRDP_TOKEN}" -H "${WNAME}" -s "cf_worker_sync_status" -S "${NRDP_STATE}" -o "${NRDP_OUTPUT}" >> "$LOG_FILE" 2>&1 || true
log "       NRDP result sent: state=${NRDP_STATE}"

# ---------- Done ----------
log ""
log "**********************************"
log "CloudFirst Worker Sync completed. (errors: ${SYNC_ERRORS})"
log "**********************************"
