#!/usr/bin/env bash
# Extrae funciones puras de install-emby-custom.sh para testearlas de forma
# aislada, sin ejecutar el resto del instalador (que asume Docker/curl reales
# y termina en un 'exit' apenas algo no está disponible).
#
# A propósito NUNCA copia la lógica a mano a un archivo de test: siempre lee
# el código fuente real de install-emby-custom.sh, así que un test nunca
# puede terminar validando una versión vieja o "creída" de una función --
# si alguien cambia la función en el script real, el test la ejercita tal
# como quedó.
#
# Límite: solo busca ANTES de la línea que arranca la generación de
# rollback-<timestamp>.sh (el 'cat > "$ROLLBACK_FILE" <<ROLLBACK_EOF'). Más
# allá de ese punto, varios nombres de función (curl_config_escape,
# http_body_snippet, etc.) se repiten a propósito DENTRO de los heredocs que
# generan rollback-<timestamp>.sh/reapply-<timestamp>.sh -- son scripts
# standalone con su propia copia de esas funciones. Extraerlas por nombre
# ahí sería ambiguo; esas copias se ejercitan aparte, corriendo los scripts
# generados de verdad contra los stubs de tests/integration.

INSTALLER_SCRIPT="${INSTALLER_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/install-emby-custom.sh}"

_extractor_boundary_line() {
    grep -n '^cat > "\$ROLLBACK_FILE"' "$INSTALLER_SCRIPT" | head -n1 | cut -d: -f1
}

# extract_function NAME -- imprime por stdout el código fuente de la función
# NAME tal como está HOY en install-emby-custom.sh (desde 'NAME() {' hasta el
# '}' de cierre en la misma columna).
extract_function() {
    local name="$1"
    local boundary
    boundary="$(_extractor_boundary_line)"
    [ -n "$boundary" ] || { echo "extract_functions.sh: no encontré el límite de heredocs en $INSTALLER_SCRIPT" >&2; return 1; }
    awk -v name="$name" -v boundary="$boundary" '
        NR >= boundary { exit }
        $0 ~ ("^" name "\\(\\) \\{$") { grabbing = 1 }
        grabbing { print }
        grabbing && /^}$/ { exit }
    ' "$INSTALLER_SCRIPT"
}

# source_functions NAME... -- extrae y define cada función pedida en el
# shell actual (falla fuerte si alguna no aparece: mejor un test roto y
# obvio que uno que silenciosamente no está probando nada).
source_functions() {
    local name src
    for name in "$@"; do
        src="$(extract_function "$name")"
        if [ -z "$src" ]; then
            echo "extract_functions.sh: no se encontró la función '$name' en $INSTALLER_SCRIPT (¿se renombró, o el límite de heredocs quedó desactualizado?)" >&2
            return 1
        fi
        eval "$src"
    done
}
