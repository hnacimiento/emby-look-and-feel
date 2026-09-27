#!/usr/bin/env bash
# Helper de conexión al host de nginx (reverse proxy delante de Emby) a
# partir de deploy/truenas.env (gitignored, nunca se pega en el chat). Este
# script en sí no contiene ningún dato sensible -- solo lee el .env local.
#
# Variables usadas (ver deploy/truenas.env.example):
#   NGINX_HOST_REMOTE_HOST, NGINX_HOST_REMOTE_SSH_PORT (default 22),
#   NGINX_HOST_REMOTE_SSH_USER, NGINX_HOST_REMOTE_SSH_KEY
#
# Uso:
#   ./deploy/nginx-ssh.sh                 -- abre una sesión interactiva
#   ./deploy/nginx-ssh.sh -- CMD ARGS...   -- corre CMD por SSH y sale
#   ./deploy/nginx-ssh.sh --scp SRC DEST   -- scp usando la misma config
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/truenas.env"

[ -f "$ENV_FILE" ] || {
    echo "No existe $ENV_FILE." >&2
    echo "Copiá deploy/truenas.env.example a deploy/truenas.env y completá los datos." >&2
    exit 1
}

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${NGINX_HOST_REMOTE_HOST:?Falta NGINX_HOST_REMOTE_HOST en $ENV_FILE}"
: "${NGINX_HOST_REMOTE_SSH_PORT:=22}"
: "${NGINX_HOST_REMOTE_SSH_USER:?Falta NGINX_HOST_REMOTE_SSH_USER en $ENV_FILE}"
: "${NGINX_HOST_REMOTE_SSH_KEY:?Falta NGINX_HOST_REMOTE_SSH_KEY en $ENV_FILE}"

[ -f "$NGINX_HOST_REMOTE_SSH_KEY" ] || {
    echo "NGINX_HOST_REMOTE_SSH_KEY ($NGINX_HOST_REMOTE_SSH_KEY) no existe." >&2
    exit 1
}

if [ "${1:-}" = "--scp" ]; then
    shift
    exec scp -P "$NGINX_HOST_REMOTE_SSH_PORT" -i "$NGINX_HOST_REMOTE_SSH_KEY" -o StrictHostKeyChecking=accept-new "$@"
fi

if [ "${1:-}" = "--" ]; then
    shift
fi

exec ssh -p "$NGINX_HOST_REMOTE_SSH_PORT" -i "$NGINX_HOST_REMOTE_SSH_KEY" -o StrictHostKeyChecking=accept-new "$NGINX_HOST_REMOTE_SSH_USER@$NGINX_HOST_REMOTE_HOST" "$@"
