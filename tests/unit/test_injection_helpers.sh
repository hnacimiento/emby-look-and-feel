#!/usr/bin/env bash
# shellcheck disable=SC2034 # some fixture vars are kept for symmetry/readability, not all read back
# Tests unitarios de los helpers de edición de addons (sección "11. EDICIÓN
# DE ADDONS" de install-emby-custom.sh) -- las dos familias documentadas en
# docs/ARCHITECTURE.md ("Addon injection mechanisms"). Cubre puntualmente el
# bug real encontrado en la revisión: la verificación post-sed era un
# 'grep -qF' de archivo completo, que podía dar falso positivo por
# coincidencia de substring (valores cortos como "AR") o ser un no-op total
# con un valor vacío (CORS_PROXY_URL="").
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/extract_functions.sh
source "$HERE/../lib/extract_functions.sh"

source_functions \
    sed_escape_repl grep_escape_ere json_escape \
    count_const_decl resolve_inject_anchor_line \
    set_or_die_const_string set_or_inject_const_string \
    set_if_declared_const_string set_or_inject_const_raw verify_or_warn_const_raw \
    js_string_array_literal set_or_inject_const_array_raw \
    count_property_decl set_or_die_property_string set_or_die_property_raw

# die_precheck real llama a cleanup_temp/CUSTOM_ROOT/exit -- acá alcanza con
# que aborte (exit 1) dejando el mensaje visible, porque cada llamada bajo
# test corre en un subshell (assert_exit_code), así que el 'exit' termina
# solo ese subshell, nunca la suite completa.
die_precheck() { echo "die_precheck: $1" >&2; exit 1; }
warn() { echo "warn: $1"; }

FIXTURES="$HERE/../fixtures"

fresh_fixture() {
    local name="$1" tmp
    tmp="$(mktemp)"
    cp "$FIXTURES/$name" "$tmp"
    printf '%s' "$tmp"
}

# --- set_or_die_const_string ------------------------------------------

suite "set_or_die_const_string"

F="$(fresh_fixture const-string-sample.js)"
set_or_die_const_string "$F" "DEFAULT_REGION" "AR"
assert_contains "$(cat "$F")" "const DEFAULT_REGION = 'AR'; // comentario que debe sobrevivir la edición" "reemplaza el valor y conserva comilla original + comentario"
assert_contains "$(cat "$F")" "this contains AR as a substring" "la línea que ya tenía 'AR' como substring sigue intacta (no la confundimos con la declaración real)"
rm -f "$F"

F="$(mktemp)"
printf "const X = 'a';\nconst X = 'b';\n" > "$F"
assert_exit_code 1 "declaración ambigua (misma constante dos veces) aborta en vez de editar cualquiera" \
    set_or_die_const_string "$F" X y
rm -f "$F"

F="$(mktemp)"
printf "const OTHER = 'x';\n" > "$F"
assert_exit_code 1 "declaración inexistente aborta (nunca inyecta una nueva)" \
    set_or_die_const_string "$F" NOPE y
rm -f "$F"

# --- set_or_inject_const_string -----------------------------------------

suite "set_or_inject_const_string"

F="$(mktemp)"
printf "const FIRST = 'x';\n" > "$F"
INJECT_ANCHOR_LINE=""
set_or_inject_const_string "$F" "PRIMARY_LANGUAGE" "es-AR"
assert_contains "$(cat "$F")" "const PRIMARY_LANGUAGE = \"es-AR\";" "inyecta la declaración nueva si no existía (caso real: Reviews.js/PRIMARY_LANGUAGE)"
rm -f "$F"

F="$(fresh_fixture const-string-sample.js)"
INJECT_ANCHOR_LINE=""
set_or_inject_const_string "$F" "DEFAULT_REGION" "AR"
assert_contains "$(cat "$F")" "const DEFAULT_REGION = 'AR';" "si ya existe, edita en vez de duplicar"
assert_eq "$(grep -c "DEFAULT_REGION" "$F")" "1" "no queda una declaración duplicada"
rm -f "$F"

# --- set_if_declared_const_string ---------------------------------------

suite "set_if_declared_const_string (regla de seguridad de Reviews.js/TMDB_API_KEY)"

F="$(mktemp)"
printf "const OTHER = 'x';\n" > "$F"
if set_if_declared_const_string "$F" "TMDB_API_KEY" "secret-value"; then
    _test_fail "no debería haber inyectado TMDB_API_KEY: la declaración no existía en el original"
else
    _test_ok "devuelve 1 (skip) cuando la declaración no existe"
fi
assert_not_contains "$(cat "$F")" "TMDB_API_KEY" "el archivo sigue sin ninguna mención de TMDB_API_KEY -- nunca se agrega una referencia nueva a un secreto"
rm -f "$F"

F="$(mktemp)"
printf "const TMDB_API_KEY = 'old';\n" > "$F"
if set_if_declared_const_string "$F" "TMDB_API_KEY" "new-secret"; then
    _test_ok "devuelve 0 (inyectado) cuando la declaración SÍ existía"
else
    _test_fail "debería haber inyectado: la declaración existía en el original"
fi
assert_contains "$(cat "$F")" "const TMDB_API_KEY = 'new-secret';" "el valor quedó actualizado"
rm -f "$F"

# --- set_or_die_property_string ------------------------------------------

suite "set_or_die_property_string"

F="$(fresh_fixture property-string-sample.js)"
set_or_die_property_string "$F" "CORS_PROXY_URL" ""
assert_contains "$(cat "$F")" "CORS_PROXY_URL: '', // debe poder quedar vacío" "queda realmente vacío, con la coma y el comentario final preservados (bug real: antes 'grep -qF \"\"' pasaba siempre, sin importar si el sed hizo algo)"
rm -f "$F"

F="$(mktemp)"
printf "const CONFIG = {\n    OTHERVAR: 'xARy',\n    REGION: 'US',\n};\n" > "$F"
set_or_die_property_string "$F" "REGION" "AR"
assert_contains "$(cat "$F")" "REGION: 'AR'," "se editó la propiedad correcta"
assert_contains "$(cat "$F")" "OTHERVAR: 'xARy'," "la propiedad que ya contenía 'AR' como substring no se tocó ni confundió la verificación (mismo bug que DEFAULT_REGION, en formato propiedad)"
rm -f "$F"

F="$(fresh_fixture property-string-sample.js)"
set_or_die_property_string "$F" "vignetteColorTop" "#1e1e1e"
assert_contains "$(cat "$F")" "vignetteColorTop: '#1e1e1e'," "preserva el tipo de comilla original (simple) con un valor típico de color"
rm -f "$F"

F="$(mktemp)"
printf "const CONFIG = {\n    X: 'a',\n    X: 'b',\n};\n" > "$F"
assert_exit_code 1 "propiedad ambigua (misma propiedad dos veces) aborta en vez de editar cualquiera" \
    set_or_die_property_string "$F" X y
rm -f "$F"

# --- set_or_die_property_raw ---------------------------------------------

suite "set_or_die_property_raw"

F="$(fresh_fixture property-string-sample.js)"
set_or_die_property_raw "$F" "enableIMDb" "false"
assert_contains "$(cat "$F")" "enableIMDb: false," "propiedad booleana se reemplaza y la verificación (anclada, no substring) la confirma"
rm -f "$F"

# --- js_string_array_literal / set_or_inject_const_array_raw -------------

suite "js_string_array_literal"

EMPTY_ARR=()
assert_eq "$(js_string_array_literal EMPTY_ARR)" "[]" "array bash vacío -> [] (default real: ELSEWHERE_DEFAULT_PROVIDERS/IGNORE_PROVIDERS = mostrar todo)"

ONE_ARR=("Netflix")
assert_eq "$(js_string_array_literal ONE_ARR)" '["Netflix"]' "un elemento"

MULTI_ARR=("Netflix" "HBO Max")
assert_eq "$(js_string_array_literal MULTI_ARR)" '["Netflix", "HBO Max"]' "varios elementos, separados por coma y espacio"

QUOTE_ARR=('Provider "with quotes"')
assert_eq "$(js_string_array_literal QUOTE_ARR)" '["Provider \"with quotes\""]' "comillas dentro de un elemento se escapan (json_escape)"

suite "set_or_inject_const_array_raw (DEFAULT_PROVIDERS/IGNORE_PROVIDERS de emby-elsewhere.js)"

F="$(mktemp)"
printf "const DEFAULT_PROVIDERS = [];\nconst IGNORE_PROVIDERS = [];\n" > "$F"
set_or_inject_const_array_raw "$F" "DEFAULT_PROVIDERS" '["Netflix", "HBO Max"]'
assert_contains "$(cat "$F")" 'const DEFAULT_PROVIDERS = ["Netflix", "HBO Max"];' "reemplaza un array existente por el configurado"
assert_contains "$(cat "$F")" 'const IGNORE_PROVIDERS = [];' "no toca la otra declaración"
rm -f "$F"

F="$(mktemp)"
printf "const DEFAULT_PROVIDERS = [];\n" > "$F"
set_or_inject_const_array_raw "$F" "DEFAULT_PROVIDERS" "[]"
assert_contains "$(cat "$F")" 'const DEFAULT_PROVIDERS = [];' "default real (mostrar todo) verifica bien pese a los corchetes -- son metacaracteres de ERE, la verificación tiene que escaparlos"
rm -f "$F"

F="$(mktemp)"
printf "const OTHER = 'x';\n" > "$F"
set_or_inject_const_array_raw "$F" "DEFAULT_PROVIDERS" '["Netflix"]'
assert_contains "$(cat "$F")" 'const DEFAULT_PROVIDERS = ["Netflix"];' "si la declaración no existe, la inyecta (igual que set_or_inject_const_raw)"
rm -f "$F"

print_summary
exit $?
