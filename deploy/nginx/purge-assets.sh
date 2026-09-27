#!/usr/bin/env bash
# Removes from nginx's proxy cache the entries for the files this installer
# changes (the addon .js, index.html, modules/skinmanager.js, theme.css), so
# browsers going through nginx get the new versions right after an install
# instead of the copy nginx cached for up to a day. Run ON the nginx host
# (or through deploy/nginx-ssh.sh). Safe: nginx simply re-fetches from Emby.
#
# Usage: purge-assets.sh [CACHE_DIR ...]   (default: /mnt/ram_cache /mnt/disk_cache)
set -Eeuo pipefail
DIRS=("$@")
[ "${#DIRS[@]}" -gt 0 ] || DIRS=(/mnt/ram_cache /mnt/disk_cache)
PATTERN='^KEY: .*/web/(Spotlight\.js|Reviews\.js|emby-elsewhere\.js|emby-ratings\.js|emby-linklogos\.js|emby-media-ratings\.js|index\.html|modules/skinmanager\.js|modules/themes/embymalism/theme\.css)'
n=0
for d in "${DIRS[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
        key="$(grep -a -m1 '^KEY:' "$f" | cut -c1-120)"
        rm -f "$f" && n=$((n + 1)) && echo "purged: $key"
    done < <(grep -rlE "$PATTERN" "$d" 2>/dev/null || true)
done
echo "entries purged: $n"
