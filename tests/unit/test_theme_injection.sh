#!/usr/bin/env bash
# shellcheck disable=SC2034 # some fixture vars are kept for symmetry/readability, not all read back
# Tests de la inyección de la entrada "Embymalism" en modules/skinmanager.js
# (FASE 6/9, "Preparación del tema"). Usa las funciones REALES del script
# (theme_strip_entry / theme_inject_entry / theme_verify_patched /
# theme_count_literal) y las constantes reales THEME_ANCHOR / THEME_ENTRY,
# sobre una réplica sintética de la estructura de AllThemes (no se
# versiona el skinmanager.js real de Emby).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/extract_functions.sh
source "$HERE/../lib/extract_functions.sh"

# Las constantes del tema son asignaciones simples de una línea al principio
# del script; se cargan tal cual están hoy (nunca copiadas a mano).
DASHBOARD_CONTAINER_DIR="/system/dashboard-ui"
# Solo las asignaciones literales (="..." / ='...') de la sección de
# configuración: los heredocs de rollback/reapply reasignan algunos de estos
# nombres vía shell_single_quote y no deben entrar acá.
eval "$(grep -E "^(THEME_ID|THEME_NAME|SKINMANAGER_REL|THEME_CSS_REL|THEME_ANCHOR|THEME_ENTRY|THEME_DEFAULT_ANCHOR|THEME_DEFAULT_PATCHED)=['\"]" "$INSTALLER_SCRIPT")"
source_functions theme_count_literal theme_strip_entry theme_inject_entry theme_verify_patched
# Default del script: Embymalism como tema por defecto. Los tests del otro
# modo lo ponen en 0 explícitamente.
THEME_SET_AS_DEFAULT="1"

# Réplica mínima de la forma del skinmanager.js real: una sola línea
# minificada, con la expresión DefaultTheme (que también contiene el otro
# '||"dark"' de la rama "auto", que NO debe tocarse), la entrada de Dark
# antes y la de Light después del punto de inserción.
FIXTURE_PREFIX='var DefaultController="./modules/themes/themecontroller.js",DefaultTheme=(_servicelocator.appHost.getPreferredTheme&&"windows"===_servicelocator.appHost.getPreferredTheme()?"windows":null)||"dark";if("auto"===id&&appHost.getPreferredTheme&&(id=appHost.getPreferredTheme()||"dark",requiresRegistration=!1),1);var AllThemes=[{name:"Black",id:"black",controller:DefaultController,stylesheets:[{path:"modules/themes/black/theme.css",options:{}}]},{name:"Dark",id:"dark",controller:DefaultController,infoPath:"modules/themes/dark/theme.json",isDefault:!0,stylesheets:[{path:"modules/themes/dark/theme.css",options:{cssvars:!0}}].concat(DarkContentContainerStylesheets)},'
# Lo que queda del prefijo cuando además se cambia el tema por defecto.
FIXTURE_PREFIX_DEFAULTED="${FIXTURE_PREFIX/"$THEME_DEFAULT_ANCHOR"/"$THEME_DEFAULT_PATCHED"}"
FIXTURE_SUFFIX='{name:"Light",id:"light",controller:DefaultController,infoPath:"modules/themes/light/theme.json",requires:["cssvariables"],isSettingsDefault:!defaultSettingsThemeIsMainTheme,stylesheets:[{path:"modules/themes/light/theme.css",options:{}}]}].filter(function(t){return!0});AllThemes.forEach(function(t){t.isDefault=t.id===DefaultTheme})'
FIXTURE="$FIXTURE_PREFIX$FIXTURE_SUFFIX"

make_fixture() {
    local f
    f="$(mktemp)"
    printf '%s' "$FIXTURE" > "$f"
    printf '%s' "$f"
}

suite "constantes del tema: forma esperada"

assert_eq "$THEME_ID" "embymalism" "THEME_ID es 'embymalism' (el id que verá el combo Theme)"
assert_contains "$THEME_ENTRY" "id:\"$THEME_ID\"" "THEME_ENTRY declara el id"
assert_contains "$THEME_ENTRY" 'skipForSettingsthemes:!0' "THEME_ENTRY se excluye del combo Settings theme"
assert_contains "$THEME_ENTRY" "path:\"$THEME_CSS_REL\"" "THEME_ENTRY referencia theme.css por la ruta relativa que se instala"
assert_contains "$THEME_ENTRY" '.concat(DarkContentContainerStylesheets)},' "THEME_ENTRY termina en '},' para quedar pegada delante de la entrada de Light"
assert_not_contains "$THEME_ENTRY" 'isDefault' "THEME_ENTRY no lleva isDefault (skinmanager lo recalcula desde DefaultTheme)"
assert_eq "$THEME_ANCHOR" '{name:"Light",id:"light",' "el ancla es el inicio de la entrada de Light"
assert_eq "$THEME_DEFAULT_ANCHOR" '"windows":null)||"dark"' "el ancla del tema por defecto es el literal final de la expresión DefaultTheme"
assert_eq "$THEME_DEFAULT_PATCHED" '"windows":null)||"embymalism"' "el reemplazo del tema por defecto apunta a nuestro id"
assert_eq "$(printf '%s' "$FIXTURE_PREFIX" | grep -o '||"dark"' | wc -l | tr -d ' ')" "2" "precondición: el fixture trae DOS '||\"dark\"' (DefaultTheme y la rama auto), solo uno es ancla"

suite "theme_inject_entry (THEME_SET_AS_DEFAULT=1): entrada delante de Light + tema por defecto cambiado, Dark intacto"

F="$(make_fixture)"
assert_exit_code 0 "inject devuelve 0 sobre un archivo con ambas anclas exactamente una vez" theme_inject_entry "$F"
PATCHED="$(cat "$F")"
assert_eq "$PATCHED" "$FIXTURE_PREFIX_DEFAULTED$THEME_ENTRY$FIXTURE_SUFFIX" "el resultado es exactamente prefijo(con default cambiado) + entrada + sufijo (ningún otro byte cambió)"
assert_eq "$(theme_count_literal "$F" 'id:"embymalism"')" "1" "id:\"embymalism\" aparece una sola vez en la lista"
assert_eq "$(theme_count_literal "$F" '{name:"Dark",id:"dark",controller:DefaultController,infoPath:"modules/themes/dark/theme.json",isDefault:!0,')" "1" "la entrada de Dark quedó intacta byte a byte"
assert_eq "$(theme_count_literal "$F" 'getPreferredTheme()||"dark"')" "1" "el '||\"dark\"' de la rama auto NO se tocó"
assert_eq "$(theme_count_literal "$F" "$THEME_DEFAULT_PATCHED")" "1" "DefaultTheme ahora termina en ||\"embymalism\""
assert_exit_code 0 "verify acepta el archivo recién parcheado" theme_verify_patched "$F"
rm -f "$F"

suite "theme_inject_entry (THEME_SET_AS_DEFAULT=0 / --no-default-theme): solo la entrada, DefaultTheme intacto"

THEME_SET_AS_DEFAULT="0"
F="$(make_fixture)"
assert_exit_code 0 "inject devuelve 0" theme_inject_entry "$F"
assert_eq "$(cat "$F")" "$FIXTURE_PREFIX$THEME_ENTRY$FIXTURE_SUFFIX" "solo se insertó la entrada; DefaultTheme sigue en ||\"dark\""
assert_exit_code 0 "verify (modo no-default) acepta el archivo" theme_verify_patched "$F"
THEME_SET_AS_DEFAULT="1"
assert_exit_code 1 "verify (modo default) rechaza un archivo parcheado sin el cambio de default (los modos no se confunden)" theme_verify_patched "$F"
theme_strip_entry "$F"
assert_eq "$(cat "$F")" "$FIXTURE" "strip vuelve al original también desde el modo no-default"
rm -f "$F"

# Un archivo del container que quedó de una instalación con default=1,
# cuando ahora se corre con --no-default-theme: strip lo tiene que limpiar
# ENTERO (entrada y default), no solo la parte que el modo actual conoce.
THEME_SET_AS_DEFAULT="1"
F="$(make_fixture)"
theme_inject_entry "$F"
THEME_SET_AS_DEFAULT="0"
theme_strip_entry "$F"
assert_eq "$(cat "$F")" "$FIXTURE" "strip revierte el cambio de default aunque el modo actual sea no-default (el baseline nunca arrastra un default ajeno)"
THEME_SET_AS_DEFAULT="1"
rm -f "$F"

suite "theme_inject_entry: idempotencia y condiciones de rechazo"

F="$(make_fixture)"
theme_inject_entry "$F"
BEFORE="$(cat "$F")"
assert_exit_code 1 "un segundo inject devuelve 1 (la entrada ya está)" theme_inject_entry "$F"
assert_eq "$(cat "$F")" "$BEFORE" "un segundo inject no duplica la entrada ni modifica el archivo"
rm -f "$F"

F="$(mktemp)"
printf '%s' "$FIXTURE_PREFIX" > "$F"
assert_exit_code 1 "sin ancla, inject devuelve 1" theme_inject_entry "$F"
assert_eq "$(cat "$F")" "$FIXTURE_PREFIX" "sin ancla (Emby cambió el archivo) no se toca nada -- el caller cae al modo CustomCss"
rm -f "$F"

F="$(mktemp)"
printf '%s%s' "$FIXTURE" "$FIXTURE_SUFFIX" > "$F"
assert_exit_code 1 "con el ancla repetida, inject devuelve 1" theme_inject_entry "$F"
assert_eq "$(theme_count_literal "$F" "$THEME_ANCHOR")" "2" "con el ancla repetida se rechaza (no se adivina cuál es la buena)"
rm -f "$F"

suite "theme_strip_entry: vuelve al original byte a byte (baseline)"

F="$(make_fixture)"
theme_inject_entry "$F"
theme_strip_entry "$F"
assert_eq "$(cat "$F")" "$FIXTURE" "strip después de inject devuelve el original exacto"
theme_strip_entry "$F"
assert_eq "$(cat "$F")" "$FIXTURE" "strip sobre un archivo sin entrada no cambia nada (idempotente)"
rm -f "$F"

F="$(mktemp)"
printf '%s\n' "$FIXTURE" > "$F"
theme_inject_entry "$F"
theme_strip_entry "$F"
assert_eq "$(wc -c < "$F" | tr -d ' ')" "$(( ${#FIXTURE} + 1 ))" "se preserva el salto de línea final del archivo (lectura con IFS= read -d '')"
rm -f "$F"

suite "theme_verify_patched: detecta inconsistencias"

F="$(make_fixture)"
assert_exit_code 1 "verify rechaza un archivo sin la entrada" theme_verify_patched "$F"

F2="$(mktemp)"
printf '%s%s%s%s' "$FIXTURE_PREFIX_DEFAULTED" "$THEME_ENTRY" "$THEME_ENTRY" "$FIXTURE_SUFFIX" > "$F2"
assert_exit_code 1 "verify rechaza la entrada duplicada" theme_verify_patched "$F2"

F3="$(mktemp)"
printf '%s%s%s%s' "$FIXTURE_PREFIX_DEFAULTED" "$THEME_ENTRY" '{name:"Sep",id:"sep"},' "$FIXTURE_SUFFIX" > "$F3"
assert_exit_code 1 "verify rechaza la entrada separada del ancla (no está pegada delante de Light)" theme_verify_patched "$F3"

F4="$(mktemp)"
printf '%s%s%s' "$FIXTURE_PREFIX" "$THEME_ENTRY" "$FIXTURE_SUFFIX" > "$F4"
assert_exit_code 1 "verify (default=1) rechaza un archivo con la entrada pero con DefaultTheme sin cambiar" theme_verify_patched "$F4"
rm -f "$F" "$F2" "$F3" "$F4"

suite "theme_inject_entry: sin el ancla del default (Emby cambió DefaultTheme) se rechaza entero, sin dejar media inyección"

F="$(mktemp)"
printf '%s%s' "${FIXTURE_PREFIX/"$THEME_DEFAULT_ANCHOR"/'"windows":null)||"black"'}" "$FIXTURE_SUFFIX" > "$F"
BEFORE="$(cat "$F")"
assert_exit_code 1 "inject devuelve 1" theme_inject_entry "$F"
assert_eq "$(cat "$F")" "$BEFORE" "el archivo no se tocó (ni la entrada ni el default)"
rm -f "$F"

suite "metacaracteres: la entrada se trata como texto literal, no como glob"

# THEME_ENTRY trae '[', ']', '!' y '*'-like; si alguna sustitución la usara
# sin comillas, bash la interpretaría como patrón y estos tres tests
# fallarían (o peor: matchearían de más).
assert_contains "$THEME_ENTRY" '[' "la entrada contiene corchetes (precondición del test)"
F="$(make_fixture)"
theme_inject_entry "$F"
assert_eq "$(theme_count_literal "$F" "$THEME_ENTRY")" "1" "count literal encuentra la entrada exacta"
assert_eq "$(theme_count_literal "$F" 'requires:["cssvariables"],skipForSettingsthemes:!0')" "1" "un fragmento con corchetes y '!' se cuenta como literal"
rm -f "$F"

print_summary
exit $?
