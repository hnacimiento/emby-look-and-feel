#!/usr/bin/env bash
# Removes from nginx's proxy cache the entries for the files this installer
# changes (the addon .js, index.html, modules/skinmanager.js, theme.css), so
# browsers going through nginx get the new versions right after an install
# instead of the copy nginx cached for up to a day. Run ON the nginx host
# (or through deploy/nginx-ssh.sh). Safe: nginx simply re-fetches from Emby.
#
# Since installer 1.2.0 the addon <script> tags carry ?v=<hash>, and Emby
# loads its own modules with ?v=<emby version>, so both get a new cache key
# when they change. What still keeps its URL is theme.css (and any request
# made without Emby's ?v=): run this after an install that changed the CSS.
# --all-web is a blunt reset of every cached /web/ entry, e.g. after an Emby
# upgrade if something still looks stale.
#
# Usage: purge-assets.sh [--all-web] [CACHE_DIR ...]   (default: /mnt/ram_cache /mnt/disk_cache)
#   --all-web  purge every cached /web/ entry, not only the installer's files
set -Eeuo pipefail
ALL_WEB=0
DIRS=()
for arg in "$@"; do
    case "$arg" in
        --all-web) ALL_WEB=1 ;;
        -*) echo "usage: $0 [--all-web] [CACHE_DIR ...]" >&2; exit 2 ;;
        *) DIRS+=("$arg") ;;
    esac
done
[ "${#DIRS[@]}" -gt 0 ] || DIRS=(/mnt/ram_cache /mnt/disk_cache)
if [ "$ALL_WEB" = "1" ]; then
    PATTERN='^KEY: .*/web/'
else
    PATTERN='^KEY: .*/web/(Spotlight\.js|Reviews\.js|emby-elsewhere\.js|emby-ratings\.js|emby-linklogos\.js|emby-media-ratings\.js|index\.html|modules/skinmanager\.js|modules/themes/embymalism/theme\.css)'
fi
n=0
for d in "${DIRS[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
        # Only the URI field of the key: the rest of the cache key carries the
        # client's Authorization/Cookie values, which must never be printed.
        key="$(grep -a -m1 '^KEY:' "$f" | cut -d'|' -f3 | cut -c1-120)"
        rm -f "$f" && n=$((n + 1)) && echo "purged: $key"
    done < <(grep -rlaE "$PATTERN" "$d" 2>/dev/null || true)
done
echo "entries purged: $n"
