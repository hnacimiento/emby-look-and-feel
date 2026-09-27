#!/usr/bin/env bash
# Tests de integración de rollback-<timestamp>.sh: genera el script REAL
# (extraído del heredoc de install-emby-custom.sh) y lo corre contra los
# stubs de docker/curl, ejercitando puntos de la tabla de "Failure state
# machine" de docs/ARCHITECTURE.md en vez de solo razonar sobre el código.
#
# El caso más importante de este archivo es
# "docker exec falla justo en la verificación de hash" -- es exactamente el
# escenario del bug real que arregló una revisión posterior (los
# 'docker exec ... sha256sum | awk' agregados para verificar cada restore no
# estaban protegidos con '|| true'; bajo 'set -Eeuo pipefail' eso cortaba el
# resto del loop de restauración a mitad de camino). Este test falla si esa
# protección alguna vez se pierde.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/container_stub.sh
source "$HERE/../lib/container_stub.sh"

STUBS_PATH="$HERE/../stubs"
export PATH="$STUBS_PATH:$PATH"

# setup_backup_and_container SCRATCH -- deja un container con la versión
# "instalada" y un backup con la versión "anterior" para cada uno de los 6
# JS + index.html, listos para que rollback.sh los restaure.
setup_backup_and_container() {
    local scratch="$1"
    printf 'INSTALLED-index.html' > "$scratch/container/system/dashboard-ui/index.html"
    printf 'BACKUP-index.html' > "$scratch/backup/index.html"
    for js in "${JS_NAMES_FOR_TEST[@]}"; do
        printf 'INSTALLED-%s' "$js" > "$scratch/container/system/dashboard-ui/$js"
        printf 'BACKUP-%s' "$js" > "$scratch/backup/$js"
    done
    printf '{"CustomCss": "@import url(\\"https://old.example/old.css\\");"}' > "$scratch/backup/branding-before.json"
}

run_rollback() {
    local scratch="$1"
    bash "$scratch/rollback.sh"
}

# --- Caso 1: todo restaura bien -------------------------------------------

suite "rollback: caso feliz (todo restaura y verifica OK)"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"

export STUB_CURL_STATUS=200
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_CURL_STATUS
assert_eq "$CODE" "0" "exit 0 cuando todo restaura y verifica bien"
assert_contains "$OUT" "ROLLBACK: SUCCESS" "reporta SUCCESS"
for js in "${JS_NAMES_FOR_TEST[@]}"; do
    assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/$js")" "BACKUP-$js" "$js quedó restaurado al contenido del backup"
done
rm -rf "$SCRATCH"

# --- Caso 2: docker exec falla en la verificación de hash (el bug real) --

suite "rollback: docker exec falla en la verificación de hash de UN addon (regresión del fix || true)"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"

export STUB_CURL_STATUS=200
export STUB_DOCKER_EXEC_FAIL_PATTERN="sha256sum '$SCRATCH/container/system/dashboard-ui/Spotlight.js'"
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_CURL_STATUS STUB_DOCKER_EXEC_FAIL_PATTERN

# Lo crítico: el loop tiene que haber seguido después de Spotlight.js y
# haber intentado los addons siguientes (Reviews.js) y el índice -- si la
# protección '|| true' faltara, 'set -e' cortaría rollback.sh ahí mismo y
# ninguna de estas líneas existiría en la salida.
assert_contains "$OUT" "restored Reviews.js" "el loop siguió después del fallo en Spotlight.js y llegó a Reviews.js (si esto falta, volvió el bug del || true)"
assert_contains "$OUT" "Spotlight.js was copied but the restored hash does not match" "Spotlight.js se reporta como fallido (no como si nada hubiera pasado), porque el hash no se pudo verificar"
assert_contains "$OUT" "ROLLBACK: PARTIAL" "resultado PARTIAL: algunos recursos restauraron bien, Spotlight.js no"
assert_eq "$CODE" "1" "exit 1 en un rollback PARTIAL (el contrato de rollback-<ts>.sh es 0 solo si TODO restauró)"
rm -rf "$SCRATCH"

# --- Caso 3: docker cp falla para un addon --------------------------------

suite "rollback: docker cp falla al restaurar UN addon"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"

export STUB_CURL_STATUS=200
export STUB_DOCKER_CP_FAIL_PATTERN="Reviews.js"
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_CURL_STATUS STUB_DOCKER_CP_FAIL_PATTERN
assert_contains "$OUT" "ERROR restoring Reviews.js" "Reviews.js se reporta como fallido"
assert_contains "$OUT" "OK restored Spotlight.js" "los demás addons restauran bien igual (el fallo de uno no frena a los otros)"
assert_contains "$OUT" "ROLLBACK: PARTIAL" "resultado PARTIAL"
assert_eq "$CODE" "1" "exit 1"
rm -rf "$SCRATCH"

# --- Caso 4: el container ya no existe ------------------------------------

suite "rollback: el container ya no existe"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"

export STUB_DOCKER_CONTAINER_EXISTS=0
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_DOCKER_CONTAINER_EXISTS
assert_contains "$OUT" "container test-container does not exist" "avisa que el container ya no existe"
for js in "${JS_NAMES_FOR_TEST[@]}"; do
    assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/$js")" "INSTALLED-$js" "$js no se tocó (nunca se intentó nada contra un container inexistente): $js"
done
rm -rf "$SCRATCH"

# --- Caso 5: falla el restore del CSS -------------------------------------

suite "rollback: falla la restauración del CSS (los archivos sí restauran)"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"
touch "$SCRATCH/secrets.env"

export STUB_CURL_STATUS=500
export STUB_CURL_BODY='{"error":"internal"}'
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_CURL_STATUS STUB_CURL_BODY
assert_contains "$OUT" "ERROR restoring Custom CSS (HTTP 500)" "reporta el status HTTP real del fallo"
assert_contains "$OUT" '{"error":"internal"}' "incluye el cuerpo de la respuesta en el mensaje de error (antes se descartaba)"
assert_contains "$OUT" "ROLLBACK: PARTIAL" "PARTIAL: los archivos restauraron, el CSS no"
assert_eq "$CODE" "1" "exit 1"
rm -rf "$SCRATCH"

# --- Caso 6: el directorio de backup se perdió, pero el .tgz portátil sí --

suite "rollback: BACKUP_DIR no existe, pero el .tgz portátil sí -- debe extraerlo solo y restaurar igual"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"

# El .tgz se arma calcado a lo que hace install-emby-custom.sh en FASE 14:
# tar -czf "$BACKUP_TGZ" -C "$BACKUP_ROOT" "$TIMESTAMP" -- el nombre del
# directorio DENTRO del tgz tiene que ser basename("$BACKUP_DIR") ("backup"
# en este harness), porque así lo reconstruye rollback.sh al extraer.
tar -czf "$SCRATCH/emby-backup-test.tgz" -C "$SCRATCH" "backup"
rm -rf "$SCRATCH/backup"

export STUB_CURL_STATUS=200
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_CURL_STATUS
assert_contains "$OUT" "extracting from the portable backup" "avisa que está extrayendo del .tgz en vez de fallar directo"
assert_contains "$OUT" "ROLLBACK: SUCCESS" "restaura igual de bien que si el directorio original hubiera estado"
assert_eq "$CODE" "0" "exit 0"
for js in "${JS_NAMES_FOR_TEST[@]}"; do
    assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/$js")" "BACKUP-$js" "$js quedó restaurado al contenido del backup (leído desde el .tgz, no del directorio original que ya no existe): $js"
done
rm -rf "$SCRATCH"

# --- Caso 7: ni el directorio ni el .tgz existen --------------------------

suite "rollback: ni BACKUP_DIR ni el .tgz existen -- debe fallar explícito, sin inventar nada"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
rm -rf "$SCRATCH/backup"

run_and_capture OUT CODE run_rollback "$SCRATCH"
assert_contains "$OUT" "Nothing to restore from" "mensaje explícito, no un fallo genérico ni un intento silencioso"
assert_eq "$CODE" "1" "exit 1"
rm -rf "$SCRATCH"

# --- Caso 8: tema Embymalism -- skinmanager.js vuelve al original y theme.css
#     se elimina (no existía antes de instalar) -------------------------------

suite "rollback: tema (skinmanager.js restaurado desde backup, theme.css eliminado, sin chmod ruidoso)"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"
mkdir -p "$SCRATCH/container/system/dashboard-ui/modules/themes/embymalism"
printf 'PATCHED-skinmanager' > "$SCRATCH/container/system/dashboard-ui/modules/skinmanager.js"
printf 'ORIGINAL-skinmanager' > "$SCRATCH/backup/skinmanager.js"
printf 'INSTALLED-theme.css' > "$SCRATCH/container/system/dashboard-ui/modules/themes/embymalism/theme.css"
# Un addon que NO existía antes de instalar: sin backup, se elimina -- y el
# chmod posterior no debe quejarse de que ya no está.
rm -f "$SCRATCH/backup/Reviews.js"

export STUB_CURL_STATUS=200
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_CURL_STATUS
assert_eq "$CODE" "0" "exit 0"
assert_contains "$OUT" "OK restored skinmanager.js" "skinmanager.js se restaura desde el backup"
assert_eq "$(cat "$SCRATCH/container/system/dashboard-ui/modules/skinmanager.js")" "ORIGINAL-skinmanager" "skinmanager.js quedó con el contenido original de Emby (backup)"
assert_contains "$OUT" "OK removed theme.css" "theme.css se elimina porque no existía antes de instalar"
assert_eq "$([ -f "$SCRATCH/container/system/dashboard-ui/modules/themes/embymalism/theme.css" ] && echo present || echo absent)" "absent" "theme.css ya no está en el container"
assert_contains "$OUT" "OK removed Reviews.js" "el addon sin backup se elimina"
assert_not_contains "$OUT" "No such file or directory" "el chmod final no se queja de archivos que se acaban de eliminar"
rm -rf "$SCRATCH"

# --- Caso 9: el backup no trae skinmanager.js (instalación en modo customcss
#     o Emby sin ese archivo): se avisa y no cuenta como fallo ------------------

suite "rollback: sin backup de skinmanager.js -- WARNING, no fallo"
SCRATCH="$(mktemp -d)"
generate_rollback_script "$SCRATCH" >/dev/null
setup_backup_and_container "$SCRATCH"

export STUB_CURL_STATUS=200
run_and_capture OUT CODE run_rollback "$SCRATCH"
unset STUB_CURL_STATUS
assert_contains "$OUT" "WARNING: no backup of skinmanager.js" "avisa que no había backup de skinmanager.js"
assert_contains "$OUT" "ROLLBACK: SUCCESS" "sigue siendo SUCCESS (el WARNING de 'no había backup' no es un fallo)"
assert_eq "$CODE" "0" "exit 0"
rm -rf "$SCRATCH"

print_summary
exit $?
