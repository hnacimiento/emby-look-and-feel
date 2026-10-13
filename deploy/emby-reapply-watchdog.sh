#!/usr/bin/env bash
# Watchdog for the installed customizations: if the Emby container was
# recreated (image update, app reinstall, network change) its /system is
# stock again, so the addons, the theme entry in skinmanager.js and the
# index.html <script> tags are gone. This script notices and puts them back.
# Meant for cron on the Emby host (TrueNAS: System Settings -> Advanced ->
# Cron Jobs), e.g. every 15 min:
#
#   /mnt/toolbox/scripts/emby-reapply-watchdog.sh --container ix-emby-emby-1 \
#       --custom /mnt/toolbox/configs/emby/custom \
#       --installer /mnt/toolbox/scripts/install-emby-custom.sh
#
# Checks (any failing one means "customizations missing"):
#   1. every addon listed in the newest manifest exists in the container;
#   2. index.html references every addon;
#   3. if the last install used theme mode, skinmanager.js contains the
#      theme entry and theme.css exists.
# What it does then:
#   - same Emby version as at install time: runs the newest
#     reapply-<timestamp>.sh (re-copies what is staged, downloads nothing);
#   - Emby was upgraded (or downgraded): the staged index.html/skinmanager.js
#     are the old version's files, so reapply would be wrong. With
#     --installer it runs a full `install-emby-custom.sh --silent` instead
#     (that downloads the addons/CSS again and rebuilds everything from the
#     new Emby; it uses the installer's own config file and state file);
#     without --installer it only logs that the installer must be re-run.
# Exit 0 = healthy, reapplied or reinstalled OK; 1 = reapply/reinstall failed
# or a reinstall is needed; 2 = usage/precondition. Logs to <custom>/watchdog.log.
set -Eeuo pipefail

USAGE="usage: $0 --container NAME --custom /path/to/emby/custom [--installer /path/to/install-emby-custom.sh] [--dry-run]"
CONTAINER=""; CUSTOM=""; INSTALLER=""; DRY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --container) CONTAINER="$2"; shift 2 ;;
        --custom) CUSTOM="$2"; shift 2 ;;
        --installer) INSTALLER="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
done
[ -n "$CONTAINER" ] && [ -n "$CUSTOM" ] || { echo "$USAGE" >&2; exit 2; }
if [ -n "$INSTALLER" ] && [ ! -x "$INSTALLER" ]; then
    echo "--installer $INSTALLER is not an executable file" >&2; exit 2
fi

LOG="$CUSTOM/watchdog.log"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

MANIFEST="$(ls -t "$CUSTOM"/manifest-*.json 2>/dev/null | head -1 || true)"
REAPPLY="$(ls -t "$CUSTOM"/reapply-*.sh 2>/dev/null | head -1 || true)"
[ -n "$MANIFEST" ] && [ -n "$REAPPLY" ] || { log "no manifest/reapply under $CUSTOM: nothing to watch"; exit 2; }
grep -q '"install_result": "SUCCESS"' "$MANIFEST" || { log "last manifest is not SUCCESS ($MANIFEST): not reapplying automatically"; exit 2; }

docker inspect "$CONTAINER" >/dev/null 2>&1 || { log "container $CONTAINER not found"; exit 2; }
[ "$(docker inspect "$CONTAINER" -f '{{.State.Running}}')" = "true" ] || { log "container $CONTAINER not running; will check again next run"; exit 0; }

DASH=/system/dashboard-ui
PROBLEMS=()
# Addons from the manifest "files" array (one per line, quoted).
while IFS= read -r js; do
    docker exec "$CONTAINER" sh -c "test -s '$DASH/$js'" 2>/dev/null || PROBLEMS+=("missing $js")
    docker exec "$CONTAINER" sh -c "grep -qF '$js' '$DASH/index.html'" 2>/dev/null || PROBLEMS+=("index.html lacks $js")
done < <(awk '/"files": \[/{f=1;next} f&&/\]/{exit} f{gsub(/[",[:space:]]/,""); if($0!="")print}' "$MANIFEST")

if grep -q '"mode": "theme"' "$MANIFEST"; then
    docker exec "$CONTAINER" sh -c "grep -qF 'id:\"embymalism\"' '$DASH/modules/skinmanager.js'" 2>/dev/null || PROBLEMS+=("theme entry missing in skinmanager.js")
    docker exec "$CONTAINER" sh -c "test -s '$DASH/modules/themes/embymalism/theme.css'" 2>/dev/null || PROBLEMS+=("theme.css missing")
fi

if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    log "healthy: customizations present in $CONTAINER"
    exit 0
fi

log "drift detected: ${PROBLEMS[*]}"
INSTALLED_VER="$(grep -o '"emby_server_version": "[^"]*"' "$MANIFEST" | cut -d'"' -f4 || true)"
EMBY_URL_M="$(grep -o '"emby_url": "[^"]*"' "$MANIFEST" | cut -d'"' -f4 || true)"
CURRENT_VER="$(curl -s -m 10 "$EMBY_URL_M/emby/System/Info/Public" 2>/dev/null | grep -oE '"Version":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"

if [ -n "$INSTALLED_VER" ] && [ -n "$CURRENT_VER" ] && [ "$INSTALLED_VER" != "unknown" ] && [ "$CURRENT_VER" != "$INSTALLED_VER" ]; then
    if [ -z "$INSTALLER" ]; then
        log "Emby changed from $INSTALLED_VER to $CURRENT_VER: not reapplying; run install-emby-custom.sh (or pass --installer to do it automatically)"
        exit 1
    fi
    if [ "$DRY" = "1" ]; then
        log "dry-run: Emby changed from $INSTALLED_VER to $CURRENT_VER; would run $INSTALLER --silent --container=$CONTAINER"
        exit 0
    fi
    log "Emby changed from $INSTALLED_VER to $CURRENT_VER: running $INSTALLER --silent --container=$CONTAINER"
    if "$INSTALLER" --silent --container="$CONTAINER" >> "$LOG" 2>&1; then
        log "reinstall finished OK"
        exit 0
    else
        rc=$?
        log "reinstall exited with $rc (see above in this log; 2 = installed but the Branding step failed)"
        exit 1
    fi
fi

if [ "$DRY" = "1" ]; then
    log "dry-run: would run $REAPPLY"
    exit 0
fi
log "running $REAPPLY"
if bash "$REAPPLY" >> "$LOG" 2>&1; then
    log "reapply finished OK"
    exit 0
else
    rc=$?
    log "reapply exited with $rc (see above in this log)"
    exit 1
fi
