#!/usr/bin/env bash
# shellcheck disable=SC2034 # this file only sets globals consumed by the sourced/extracted real functions
# Materializa rollback-<timestamp>.sh / reapply-<timestamp>.sh REALES
# (extraídos de install-emby-custom.sh, nunca copiados a mano) contra un
# "container" de mentira -- un directorio local -- para poder correrlos
# contra los stubs de docker/curl en tests/integration.
#
# Por qué un heredoc trampolín y no 'eval' directo: el bloque entre
# 'cat > "$ROLLBACK_FILE" <<ROLLBACK_EOF' y el 'ROLLBACK_EOF' de cierre no es
# una lista de instrucciones para ejecutar ahora -- es TEXTO que en el
# script real se sustituye (heredoc sin comillas: $VAR y $(...) se
# resuelven, \$VAR se preserva literal) y se vuelca tal cual a un archivo.
# Si a ese bloque se le hiciera 'eval', líneas como
# 'docker inspect "\$CONTAINER" >/dev/null 2>&1 || { ... }' se ejecutarían
# de verdad en este momento en vez de quedar como texto en el archivo
# generado. Reproducir el heredoc con otro heredoc (el "trampolín") aplica
# exactamente las mismas reglas de sustitución que usa bash de por sí,
# sin reimplementarlas.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SCRIPT="${INSTALLER_SCRIPT:-$(cd "$HERE/../.." && pwd)/install-emby-custom.sh}"

JS_NAMES_FOR_TEST=(
    "emby-elsewhere.js"
    "emby-linklogos.js"
    "emby-media-ratings.js"
    "emby-ratings.js"
    "Spotlight.js"
    "Reviews.js"
)

# _heredoc_block START_LINE_REGEX END_MARKER -- imprime el contenido entre
# la línea que matchea START_LINE_REGEX (sin incluirla) y la primera línea
# igual a END_MARKER (sin incluirla).
_heredoc_block() {
    local start_re="$1" end_marker="$2"
    awk -v start="$start_re" -v end="$end_marker" '
        $0 ~ start { grabbing = 1; next }
        grabbing && $0 == end { exit }
        grabbing { print }
    ' "$INSTALLER_SCRIPT"
}

# _load_shared_restore_functions -- define $SHARED_RESTORE_FUNCTIONS en el
# shell actual, extrayendo el bloque 'read -r -d "" SHARED_RESTORE_FUNCTIONS
# <<...' del install-emby-custom.sh real (nunca copiado a mano: los scripts
# generados que se materializan acá insertan esa misma variable dentro de
# sus heredocs, así que sin esto quedaría sin definir bajo 'set -u').
_load_shared_restore_functions() {
    local block
    block="$(awk '
        /^read -r -d .. SHARED_RESTORE_FUNCTIONS <</ { grabbing = 1 }
        grabbing { print }
        grabbing && /^SHARED_RESTORE_FUNCTIONS_EOF$/ { exit }
    ' "$INSTALLER_SCRIPT")"
    [ -n "$block" ] || { echo "container_stub.sh: no encontré el bloque SHARED_RESTORE_FUNCTIONS" >&2; return 1; }
    eval "$block"
}

_run_trampoline() {
    # Recibe el bloque de heredoc por stdin, lo vuelve a envolver en un
    # heredoc sin comillas y lo procesa en el shell actual (con las
    # variables que el caller ya haya definido), imprimiendo el resultado.
    local block trampoline
    block="$(cat)"
    trampoline="$(mktemp)"
    {
        echo 'cat <<STUB_TRAMPOLINE_EOF'
        printf '%s\n' "$block"
        echo 'STUB_TRAMPOLINE_EOF'
    } > "$trampoline"
    # shellcheck disable=SC1090
    source "$trampoline"
    rm -f "$trampoline"
}

# generate_rollback_script SCRATCH_DIR -- crea el filesystem de mentira del
# container y el script rollback.sh real bajo SCRATCH_DIR, e imprime su ruta.
generate_rollback_script() {
    local scratch="$1"
    mkdir -p "$scratch/container/system/dashboard-ui" "$scratch/backup"

    local block
    block="$(_heredoc_block '^cat > "\\$ROLLBACK_FILE" <<ROLLBACK_EOF$' 'ROLLBACK_EOF')"
    [ -n "$block" ] || { echo "container_stub.sh: no encontré el bloque ROLLBACK_EOF" >&2; return 1; }

    (
        shell_single_quote() { local s="$1"; s=${s//\'/\'\\\'\'}; printf "'%s'" "$s"; }
        CONTAINER="test-container"
        EMBY_URL="http://127.0.0.1:9999"
        INDEX_CONTAINER_PATH="$scratch/container/system/dashboard-ui/index.html"
        DASHBOARD_CONTAINER_DIR="$scratch/container/system/dashboard-ui"
        SKINMANAGER_CONTAINER_PATH="$scratch/container/system/dashboard-ui/modules/skinmanager.js"
        THEME_CSS_CONTAINER_PATH="$scratch/container/system/dashboard-ui/modules/themes/embymalism/theme.css"
        BACKUP_DIR="$scratch/backup"
        BACKUP_TGZ="$scratch/emby-backup-test.tgz"
        SECRETS_FILE="$scratch/secrets.env"
        EMBY_BRANDING_POST_PATH="/System/Configuration/branding"
        TIMESTAMP="test"
        JS_NAMES=("${JS_NAMES_FOR_TEST[@]}")
        JS_NAMES_BASH_ARRAY="$(printf '    "%s"\n' "${JS_NAMES[@]}")"
        _load_shared_restore_functions
        printf '%s' "$block" | _run_trampoline
    ) > "$scratch/rollback.sh"

    chmod +x "$scratch/rollback.sh"
    printf '%s' "$scratch/rollback.sh"
}

# generate_reapply_script SCRATCH_DIR -- ídem, para reapply-<timestamp>.sh.
generate_reapply_script() {
    local scratch="$1"
    mkdir -p "$scratch/container/system/dashboard-ui" "$scratch/staged"

    local block
    block="$(_heredoc_block '^cat > "\\$REAPPLY_FILE" <<REAPPLY_EOF$' 'REAPPLY_EOF')"
    [ -n "$block" ] || { echo "container_stub.sh: no encontré el bloque REAPPLY_EOF" >&2; return 1; }

    (
        shell_single_quote() { local s="$1"; s=${s//\'/\'\\\'\'}; printf "'%s'" "$s"; }
        CONTAINER="test-container"
        EMBY_URL="http://127.0.0.1:9999"
        BASE="$scratch"
        DASHBOARD_UI="$scratch/staged"
        INDEX_CONTAINER_PATH="$scratch/container/system/dashboard-ui/index.html"
        DASHBOARD_CONTAINER_DIR="$scratch/container/system/dashboard-ui"
        SECRETS_FILE="$scratch/secrets.env"
        EMBY_BRANDING_GET_PATH="/emby/Branding/Configuration"
        EMBY_BRANDING_POST_PATH="/System/Configuration/branding"
        CSS_URL="https://example.invalid/Test.css"
        CSS_SOURCE="$scratch/downloaded-test.css"
        printf 'body { color: red; }\n' > "$CSS_SOURCE"
        # "customcss" reproduce el modo anterior (CSS embebido en Branding);
        # los tests del modo tema exportan THEME_MODE_FOR_TEST=theme.
        THEME_MODE="${THEME_MODE_FOR_TEST:-customcss}"
        SKINMANAGER_REL="modules/skinmanager.js"
        THEME_CSS_REL="modules/themes/embymalism/theme.css"
        SKINMANAGER_CONTAINER_PATH="$scratch/container/system/dashboard-ui/modules/skinmanager.js"
        THEME_CSS_CONTAINER_PATH="$scratch/container/system/dashboard-ui/modules/themes/embymalism/theme.css"
        TESTED_EMBY_VERSION="4.9.5.0"
        TIMESTAMP="test"
        JS_NAMES=("${JS_NAMES_FOR_TEST[@]}")
        JS_NAMES_BASH_ARRAY="$(printf '    "%s"\n' "${JS_NAMES[@]}")"
        _load_shared_restore_functions
        printf '%s' "$block" | _run_trampoline
    ) > "$scratch/reapply.sh"

    chmod +x "$scratch/reapply.sh"
    printf '%s' "$scratch/reapply.sh"
}
