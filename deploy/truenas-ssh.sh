#!/usr/bin/env bash
# Helper de conexión a TrueNAS a partir de deploy/truenas.env (gitignored,
# nunca se pega en el chat). Este script en sí no contiene ningún dato
# sensible -- solo lee el .env local.
#
# Uso:
#   ./deploy/truenas-ssh.sh                 -- abre una sesión interactiva
#   ./deploy/truenas-ssh.sh -- CMD ARGS...   -- corre CMD por SSH y sale
#   ./deploy/truenas-ssh.sh --scp SRC DEST   -- scp usando la misma config
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

: "${SSH_HOST:?Falta SSH_HOST en $ENV_FILE}"
: "${SSH_PORT:=22}"
: "${SSH_USER:?Falta SSH_USER en $ENV_FILE}"
: "${SSH_KEY_PATH:?Falta SSH_KEY_PATH en $ENV_FILE}"

[ -f "$SSH_KEY_PATH" ] || {
    echo "SSH_KEY_PATH ($SSH_KEY_PATH) no existe." >&2
    exit 1
}

if [ "${1:-}" = "--scp" ]; then
    shift
    exec scp -P "$SSH_PORT" -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$@"
fi

if [ "${1:-}" = "--" ]; then
    shift
fi

exec ssh -p "$SSH_PORT" -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new "$SSH_USER@$SSH_HOST" "$@"
