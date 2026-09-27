#!/usr/bin/env bash
# Installs (or updates) the Emby addons proxy files on the nginx host, the
# safe way: upload as .new, back up what is there, swap, `nginx -t` with the
# real config path, reload only if the test passes, revert everything if it
# fails. Uses deploy/nginx-ssh.sh (NGINX_HOST_REMOTE_* in deploy/truenas.env).
#
# Usage:
#   ./deploy/nginx/install.sh --vhost /etc/nginx/conf.d/emby.conf [--keys FILE] [--fail2ban] [--nginx-conf /etc/nginx/nginx.conf]
#
#   --vhost PATH      the Emby server{} file to add the two include lines to
#                     (only if they are not there yet; inserted after the
#                     first 'location' of the HTTPS server{}, before any
#                     regex location)
#   --keys FILE       a keys file produced by render-keys.sh; uploaded to
#                     snippets/emby-api-keys.conf (chmod 600)
#   --fail2ban        also install the [emby-api-proxy] jail + filter and
#                     reload fail2ban (skipped if fail2ban is not installed)
#   --nginx-conf PATH path passed to 'nginx -t -c' (default /etc/nginx/nginx.conf)
#
# Files (from deploy/nginx/etc/nginx/, mirrored 1:1):
#   conf.d/emby-api-cache.conf, snippets/emby-cors-proxy.conf,
#   snippets/emby-api-proxy.conf, snippets/emby-api-common.conf
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="$HERE/../nginx-ssh.sh"
SRC="$HERE/etc/nginx"

VHOST=""; KEYS=""; FAIL2BAN=0; NGINX_CONF="/etc/nginx/nginx.conf"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --vhost) VHOST="$2"; shift 2 ;;
        --keys) KEYS="$2"; shift 2 ;;
        --fail2ban) FAIL2BAN=1; shift ;;
        --nginx-conf) NGINX_CONF="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$VHOST" ] || { echo "usage: $0 --vhost /etc/nginx/conf.d/emby.conf [--keys FILE] [--fail2ban]" >&2; exit 2; }

# shellcheck disable=SC1091
source "$HERE/../truenas.env"
DEST="$NGINX_HOST_REMOTE_SSH_USER@$NGINX_HOST_REMOTE_HOST"

upload() { "$SSH" --scp "$1" "$DEST:$2.new" 2>&1 | grep -v "post-quantum\|store now\|openssh.com/pq" || true; }

echo "== uploading as .new =="
upload "$SRC/conf.d/emby-api-cache.conf"      /etc/nginx/conf.d/emby-api-cache.conf
upload "$SRC/snippets/emby-cors-proxy.conf"   /etc/nginx/snippets/emby-cors-proxy.conf
upload "$SRC/snippets/emby-api-proxy.conf"    /etc/nginx/snippets/emby-api-proxy.conf
upload "$SRC/snippets/emby-api-common.conf"   /etc/nginx/snippets/emby-api-common.conf
[ -n "$KEYS" ] && upload "$KEYS" /etc/nginx/snippets/emby-api-keys.conf
if [ "$FAIL2BAN" = "1" ]; then
    upload "$HERE/etc/fail2ban/filter.d/emby-api-proxy.conf" /etc/fail2ban/filter.d/emby-api-proxy.conf
    upload "$HERE/etc/fail2ban/jail.d/emby-api-proxy.conf"   /etc/fail2ban/jail.d/emby-api-proxy.conf
fi

echo "== activating on the host =="
"$SSH" -- "set -e
TS=\$(date +%Y-%m-%d_%H%M%S); VHOST='$VHOST'; NGX='$NGINX_CONF'
FILES='/etc/nginx/conf.d/emby-api-cache.conf /etc/nginx/snippets/emby-cors-proxy.conf /etc/nginx/snippets/emby-api-proxy.conf /etc/nginx/snippets/emby-api-common.conf'
[ -f /etc/nginx/snippets/emby-api-keys.conf.new ] && FILES=\"\$FILES /etc/nginx/snippets/emby-api-keys.conf\"
[ -f /etc/nginx/snippets/emby-api-keys.conf ] || [ -f /etc/nginx/snippets/emby-api-keys.conf.new ] || { echo 'ERROR: no keys file on the host and none given with --keys'; exit 1; }
mkdir -p /var/cache/nginx/emby_api; chown nginx:nginx /var/cache/nginx/emby_api 2>/dev/null || chown www-data:www-data /var/cache/nginx/emby_api 2>/dev/null || true
cp -a \"\$VHOST\" \"\$VHOST.bak.\$TS\"
for f in \$FILES; do [ -f \"\$f\" ] && cp -a \"\$f\" \"\$f.prev\"; mv \"\$f.new\" \"\$f\"; done
chmod 600 /etc/nginx/snippets/emby-api-keys.conf; chown root:root /etc/nginx/snippets/emby-api-keys.conf
for inc in emby-cors-proxy emby-api-proxy; do
  if ! grep -q \"snippets/\$inc.conf\" \"\$VHOST\"; then
    awk -v inc=\"\$inc\" 'BEGIN{done=0} /^[[:space:]]*location / && !done { print \"    include snippets/\" inc \".conf;\"; done=1 } { print }' \"\$VHOST\" > \"\$VHOST.tmp\" && mv \"\$VHOST.tmp\" \"\$VHOST\"
    echo \"include snippets/\$inc.conf added to \$VHOST\"
  fi
done
# Server-level add_header that reflects the Emby session token into the
# /api-proxy/ cookie (empty value = header not sent). Server level on
# purpose: the locations that proxy /emby/ inherit it, the ones with their
# own add_header (assets, images, proxies) do not need it.
if ! grep -q 'add_header Set-Cookie \$emby_session_cookie;' \"\$VHOST\"; then
  awk 'BEGIN{done=0} /include snippets\/emby-api-proxy.conf;/ && !done { print; print \"    # Emby session token -> cookie for /api-proxy/ (conf.d/emby-api-cache.conf); empty = not sent.\"; print \"    add_header Set-Cookie \$emby_session_cookie;\"; done=1; next } { print }' \"\$VHOST\" > \"\$VHOST.tmp\" && mv \"\$VHOST.tmp\" \"\$VHOST\"
  echo \"add_header Set-Cookie \\\$emby_session_cookie added to \$VHOST\"
fi
if nginx -t -c \"\$NGX\" 2>&1 | tail -1 | grep -q successful; then
  systemctl reload nginx && echo \"nginx: files active, config test OK, reloaded (vhost backup: \$VHOST.bak.\$TS)\"
  for f in \$FILES; do rm -f \"\$f.prev\"; done
else
  echo 'nginx -t FAILED, reverting:'; nginx -t -c \"\$NGX\" 2>&1 | tail -5
  cp -a \"\$VHOST.bak.\$TS\" \"\$VHOST\"
  for f in \$FILES; do if [ -f \"\$f.prev\" ]; then mv \"\$f.prev\" \"\$f\"; else rm -f \"\$f\"; fi; done
  nginx -t -c \"\$NGX\" 2>&1 | tail -1; exit 1
fi
if [ -f /etc/fail2ban/jail.d/emby-api-proxy.conf.new ]; then
  if command -v fail2ban-client >/dev/null 2>&1; then
    mv /etc/fail2ban/filter.d/emby-api-proxy.conf.new /etc/fail2ban/filter.d/emby-api-proxy.conf
    mv /etc/fail2ban/jail.d/emby-api-proxy.conf.new /etc/fail2ban/jail.d/emby-api-proxy.conf
    touch /var/log/nginx/emby_api_access.log /var/log/nginx/emby_cors_access.log
    fail2ban-client reload >/dev/null && fail2ban-client status emby-api-proxy | head -3
  else
    rm -f /etc/fail2ban/filter.d/emby-api-proxy.conf.new /etc/fail2ban/jail.d/emby-api-proxy.conf.new
    echo 'fail2ban not installed: jail skipped'
  fi
fi" 2>&1 | grep -v "post-quantum\|store now\|openssh.com/pq"
