#!/usr/bin/env bash
# Tests de integración de reapply-<timestamp>.sh: genera el script REAL y lo
# corre contra los stubs de docker/curl. Cubre los casos más importantes de
# ARCHITECTURE.md#reapply-recovery-model: éxito, degradación por CSS, y el
# mismo escenario de regresión (docker exec fallando en la verificación de
# hash dentro de rollback_reapply()) que test_rollback_failure_states.sh
# cubre para el rollback principal -- reapply tiene su propia copia de esa
# lógica, así que necesita su propio test para la misma regresión.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/container_stub.sh
source "$HERE/../lib/container_stub.sh"

export PATH="$HERE/../stubs:$PATH"

setup_staged_and_installed() {
    local scratch="$1"
    # index.html tiene que mencionar los 6 addons -- la fase de verificación
    # de reapply.sh hace 'grep -qF NOMBRE.js index.html' por cada uno.
    local index_body="INSTALLED-index.html"
    for js in "${JS_NAMES_FOR_TEST[@]}"; do
        index_body="$index_body <script src=\"$js\"></script>"
    done
    printf '%s' "$index_body" > "$scratch/container/system/dashboard-ui/index.html"
    printf '%s' "${index_body/INSTALLED/STAGED}" > "$scratch/staged/index.html"
    for js in "${JS_NAMES_FOR_TEST[@]}"; do
        printf 'INSTALLED-%s' "$js" > "$scratch/container/system/dashboard-ui/$js"
        printf 'STAGED-%s' "$js" > "$scratch/staged/$js"
    done
    printf "EMBY_API_KEY='test-emby-key'\n" > "$scratch/secrets.env"
}

run_reapply() {
    local scratch="$1"
    bash "$scratch/reapply.sh"
}

# --- Caso 1: reapply feliz -------------------------------------------------

suite "reapply: caso feliz (copia todo, reinstala CSS, verifica)"
SCRATCH="$(mktemp -d)"
generate_reapply_script "$SCRATCH" >/dev/null
setup_staged_and_installed "$SCRATCH"

export STUB_CURL_STATUS=200
run_and_capture OUT CODE run_reapply "$SCRATCH"
unset STUB_CURL_STATUS
assert_eq "$CODE" "0" "exit 0 en el caso feliz"
assert_contains "$OUT" "REAPPLY COMPLETED. Result: SUCCESS" "reporta SUCCESS"
for js in "${JS_NAMES_FOR_TEST[@]}"; do
    assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/$js")" "STAGED-$js" "$js quedó con el contenido recién staged"
done
rm -rf "$SCRATCH"

# --- Caso 2: falla el reinstall del CSS (no crítico) ----------------------

suite "reapply: falla el reinstall del CSS -- DEGRADED, no crítico"
SCRATCH="$(mktemp -d)"
generate_reapply_script "$SCRATCH" >/dev/null
setup_staged_and_installed "$SCRATCH"

export STUB_CURL_STATUS=503
run_and_capture OUT CODE run_reapply "$SCRATCH"
unset STUB_CURL_STATUS
assert_eq "$CODE" "2" "exit 2 (DEGRADED) cuando solo falla el CSS"
assert_contains "$OUT" "REAPPLY COMPLETED WITH DEGRADATION" "reporta la degradación"
assert_contains "$OUT" "HTTP 503" "incluye el status HTTP real del fallo de CSS"
for js in "${JS_NAMES_FOR_TEST[@]}"; do
    assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/$js")" "STAGED-$js" "$js igual quedó instalado ($js): el fallo de CSS no revierte los addons"
done
rm -rf "$SCRATCH"

# --- Caso 3: docker exec falla en la verificación de hash del rollback ----
#     de reapply (misma clase de regresión que en rollback-<timestamp>.sh,
#     pero en rollback_reapply(), su copia independiente de la lógica).

suite "reapply: docker cp falla a mitad de la copia -> dispara rollback_reapply() -> docker exec falla en su verificación de hash"
SCRATCH="$(mktemp -d)"
generate_reapply_script "$SCRATCH" >/dev/null
setup_staged_and_installed "$SCRATCH"

export STUB_CURL_STATUS=200
export STUB_DOCKER_CP_FAIL_PATTERN="$SCRATCH/staged/Reviews.js"
export STUB_DOCKER_EXEC_FAIL_PATTERN="sha256sum '$SCRATCH/container/system/dashboard-ui/Spotlight.js'"
run_and_capture OUT CODE run_reapply "$SCRATCH"
unset STUB_CURL_STATUS STUB_DOCKER_CP_FAIL_PATTERN STUB_DOCKER_EXEC_FAIL_PATTERN

assert_eq "$CODE" "1" "exit 1: la copia falló a mitad de camino, dispara rollback automático"
assert_contains "$OUT" "AUTOMATIC ROLLBACK (reapply)" "el rollback automático de reapply se activó"
# Lo crítico de este caso: el rollback_reapply() tiene que haber intentado
# TODOS los addons, no cortarse en Spotlight.js -- si la protección '|| true'
# faltara acá (es una copia de la lógica independiente de rollback-<ts>.sh),
# 'set -e' terminaría el script a mitad del loop de rollback_reapply() y
# Reviews.js/CSS nunca se intentarían.
assert_contains "$OUT" "restored Reviews.js" "rollback_reapply() siguió después del fallo de hash en Spotlight.js y llegó a Reviews.js"
assert_contains "$OUT" "Spotlight.js was copied but the restored hash does not match" "Spotlight.js se reporta con el hash no verificado, no como éxito silencioso"
rm -rf "$SCRATCH"

# --- Caso 4: modo tema -- re-copia skinmanager.js + theme.css y deja el
#     CustomCss de Branding VACÍO ------------------------------------------------

setup_staged_theme() {
    local scratch="$1"
    mkdir -p "$scratch/staged/modules/themes/embymalism" \
             "$scratch/container/system/dashboard-ui/modules"
    printf 'STAGED-skinmanager' > "$scratch/staged/modules/skinmanager.js"
    printf 'STAGED-theme.css' > "$scratch/staged/modules/themes/embymalism/theme.css"
    printf 'INSTALLED-skinmanager' > "$scratch/container/system/dashboard-ui/modules/skinmanager.js"
}

suite "reapply: modo tema (skinmanager.js + theme.css re-copiados, CustomCss de Branding vacío)"
SCRATCH="$(mktemp -d)"
export THEME_MODE_FOR_TEST=theme
generate_reapply_script "$SCRATCH" >/dev/null
unset THEME_MODE_FOR_TEST
setup_staged_and_installed "$SCRATCH"
setup_staged_theme "$SCRATCH"

export STUB_CURL_STATUS=200
export STUB_CURL_RECORD_BODY_FILE="$SCRATCH/curl-bodies.txt"
run_and_capture OUT CODE run_reapply "$SCRATCH"
unset STUB_CURL_STATUS STUB_CURL_RECORD_BODY_FILE
assert_eq "$CODE" "0" "exit 0"
assert_contains "$OUT" "OK skinmanager.js + theme.css" "copió el tema"
assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/modules/skinmanager.js")" "STAGED-skinmanager" "skinmanager.js quedó con el contenido staged (parcheado)"
assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/modules/themes/embymalism/theme.css")" "STAGED-theme.css" "theme.css quedó con el contenido staged (el directorio se creó solo)"
assert_contains "$OUT" "Leaving Branding Custom CSS empty" "en modo tema no reinstala el CSS en Branding: lo vacía"
assert_contains "$(cat "$SCRATCH/curl-bodies.txt")" '{"CustomCss": ""}' "el payload enviado a Branding es un CustomCss VACÍO"
assert_not_contains "$(cat "$SCRATCH/curl-bodies.txt")" 'color: red' "el CSS descargado NO se mandó a Branding (vive en theme.css)"
assert_contains "$OUT" "OK modules/skinmanager.js (sha256 OK)" "verificó el hash de skinmanager.js instalado"
rm -rf "$SCRATCH"

# --- Caso 5: modo tema, pero el staging no tiene los archivos del tema ---------

suite "reapply: modo tema sin skinmanager.js/theme.css en staging -- falla ANTES de tocar nada"
SCRATCH="$(mktemp -d)"
export THEME_MODE_FOR_TEST=theme
generate_reapply_script "$SCRATCH" >/dev/null
unset THEME_MODE_FOR_TEST
setup_staged_and_installed "$SCRATCH"

export STUB_CURL_STATUS=200
run_and_capture OUT CODE run_reapply "$SCRATCH"
unset STUB_CURL_STATUS
assert_eq "$CODE" "1" "exit 1"
assert_contains "$OUT" "missing $SCRATCH/staged/modules/skinmanager.js" "dice exactamente qué falta"
for js in "${JS_NAMES_FOR_TEST[@]}"; do
    assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/$js")" "INSTALLED-$js" "$js no se tocó (la precondición falló antes de copiar): $js"
done
rm -rf "$SCRATCH"

# --- Caso 6: modo customcss (fallback) sigue funcionando igual que siempre -----

suite "reapply: modo customcss (fallback) manda el CSS completo a Branding"
SCRATCH="$(mktemp -d)"
generate_reapply_script "$SCRATCH" >/dev/null
setup_staged_and_installed "$SCRATCH"

export STUB_CURL_STATUS=200
export STUB_CURL_RECORD_BODY_FILE="$SCRATCH/curl-bodies.txt"
run_and_capture OUT CODE run_reapply "$SCRATCH"
unset STUB_CURL_STATUS STUB_CURL_RECORD_BODY_FILE
assert_eq "$CODE" "0" "exit 0"
assert_contains "$(cat "$SCRATCH/curl-bodies.txt")" 'color: red' "el CSS descargado se embebe en el payload de Branding"
assert_not_contains "$OUT" "skinmanager.js" "en modo customcss no toca skinmanager.js"
rm -rf "$SCRATCH"

print_summary
exit $?
