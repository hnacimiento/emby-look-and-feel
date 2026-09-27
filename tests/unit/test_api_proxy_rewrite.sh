#!/usr/bin/env bash
# shellcheck disable=SC2034 # some fixture vars are kept for symmetry/readability, not all read back
# Tests de rewrite_api_base (modo API proxy): reescritura de las bases de
# URL de las APIs de terceros en los addons por la del proxy nginx, y de
# assert_no_third_party_keys (ninguna key real puede quedar en un JS).
# Usa las funciones REALES del script sobre fixtures con la forma exacta
# de las URLs que traen los addons de upstream (template literals).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/extract_functions.sh
source "$HERE/../lib/extract_functions.sh"

# die_precheck real termina el proceso. Acá también termina (exit 1), pero
# assert_exit_code corre cada comando en un subshell, así que el test solo
# ve el código de salida; las funciones usan '... || die_precheck', que
# con un 'return 1' seguirían ejecutando el resto de la función.
die_precheck() { echo "DIE: $*" >&2; exit 1; }
source_functions sed_escape_repl sed_escape_pattern rewrite_api_base assert_no_third_party_keys
eval "$(grep -E "^(API_BASE_MDBLIST|API_BASE_TMDB|API_BASE_KINOPOISK|API_KEY_PLACEHOLDER)=['\"]" "$INSTALLER_SCRIPT")"

PROXY="https://emby.example.test/api-proxy/"

make_fixture() {
    local f
    f="$(mktemp)"
    cat > "$f" <<'EOF'
const a = `https://api.themoviedb.org/3/tv/${tvId}/season/${season}?api_key=${TMDB_API_KEY}`;
const b = `https://api.themoviedb.org/3/tv/${tvId}/season/${season}/episode/${episode}?api_key=${TMDB_API_KEY}`;
const c = `https://api.mdblist.com/tmdb/${type}/${tmdbId}?apikey=${MDBLIST_API_KEY}`;
const d = `https://kinopoiskapiunofficial.tech/api/v2.2/films?keyword=${encodeURIComponent(title)}&yearFrom=${year}&yearTo=${year}`;
// docs: https://kinopoiskapiunofficial.tech/
const unrelated = 'https://www.themoviedb.org/movie/1'; // sitio web, no la API: no debe tocarse
EOF
    printf '%s' "$f"
}

suite "constantes: bases de API tal como las escriben los addons"
assert_eq "$API_BASE_TMDB" "https://api.themoviedb.org/" "base TMDB con barra final"
assert_eq "$API_BASE_MDBLIST" "https://api.mdblist.com/" "base MDBList con barra final"
assert_eq "$API_BASE_KINOPOISK" "https://kinopoiskapiunofficial.tech/" "base Kinopoisk con barra final"
assert_ne "$API_KEY_PLACEHOLDER" "" "el placeholder no es vacío (los addons apagan el proveedor si la key está vacía)"

suite "rewrite_api_base: reescribe todas las ocurrencias y devuelve cuántas"

F="$(make_fixture)"
N="$(rewrite_api_base "$F" "$API_BASE_TMDB" "${PROXY}tmdb/")"
assert_eq "$N" "2" "TMDB: 2 ocurrencias reescritas"
assert_eq "$(grep -c 'https://api.themoviedb.org/' "$F")" "0" "no queda ninguna base TMDB original"
assert_contains "$(cat "$F")" '`https://emby.example.test/api-proxy/tmdb/3/tv/${tvId}/season/${season}?api_key=${TMDB_API_KEY}`' "la URL completa queda bien formada (ruta y query intactos, solo cambia la base)"
assert_contains "$(cat "$F")" "https://www.themoviedb.org/movie/1" "el sitio web de TMDB (no la API) no se toca"

N="$(rewrite_api_base "$F" "$API_BASE_MDBLIST" "${PROXY}mdblist/")"
assert_eq "$N" "1" "MDBList: 1 ocurrencia"
assert_contains "$(cat "$F")" '`https://emby.example.test/api-proxy/mdblist/tmdb/${type}/${tmdbId}?apikey=${MDBLIST_API_KEY}`' "MDBList reescrita"

N="$(rewrite_api_base "$F" "$API_BASE_KINOPOISK" "${PROXY}kinopoisk/")"
assert_eq "$N" "2" "Kinopoisk: 2 ocurrencias (la llamada y el comentario de docs; ambas se reescriben, es inofensivo)"
assert_eq "$(grep -c 'kinopoiskapiunofficial.tech/' "$F")" "0" "no queda ninguna base Kinopoisk original"
rm -f "$F"

suite "rewrite_api_base bajo 'set -E' + trap ERR (regresión: instalación real abortada en la línea del rewrite)"
# El script real corre con 'set -Eeuo pipefail' y un trap ERR. 'grep -o'
# devuelve 1 cuando no encuentra nada (el caso NORMAL para after_from tras
# reescribir), y sin el '|| true' dentro del pipeline el trap disparaba y
# la instalación real terminaba en "ERROR NO CONTROLADO" aunque el rewrite
# hubiera salido perfecto. Los tests sin trap no lo veían.
F="$(make_fixture)"
run_and_capture OUT CODE bash -c '
    set -Eeuo pipefail
    trap "echo TRAP_ERR; exit 99" ERR
    source "'"$HERE"'/../lib/extract_functions.sh"
    die_precheck() { echo "DIE: $*" >&2; exit 1; }
    source_functions sed_escape_repl sed_escape_pattern rewrite_api_base
    N="$(rewrite_api_base "'"$F"'" "https://api.themoviedb.org/" "https://p.test/tmdb/")"
    echo "N=$N"
'
assert_eq "$CODE" "0" "no dispara el trap ERR (exit 0)"
assert_contains "$OUT" "N=2" "devuelve el conteo igual que sin trap"
assert_not_contains "$OUT" "TRAP_ERR" "el trap ERR no se ejecutó"
rm -f "$F"

suite "rewrite_api_base: falla ruidosamente si la base no existe (upstream cambió la URL)"
F="$(make_fixture)"
assert_exit_code 1 "sin la base en el archivo devuelve 1 (die_precheck)" rewrite_api_base "$F" "https://api.omdbapi.com/" "${PROXY}omdb/"
assert_eq "$(cat "$F")" "$(cat "$(make_fixture)")" "el archivo no se modificó"
rm -f "$F"

suite "assert_no_third_party_keys: detecta una key real, acepta el placeholder"
F="$(mktemp)"
TMDB_API_KEY="0123456789abcdef0123456789abcdef"
MDBLIST_API_KEY=""
KINOPOISK_API_KEY="kp-secret-value"
printf 'TMDB_API_KEY: "%s", KINOPOISK: "%s"\n' "$API_KEY_PLACEHOLDER" "$API_KEY_PLACEHOLDER" > "$F"
assert_exit_code 0 "solo placeholders -> OK" assert_no_third_party_keys "$F"
printf 'TMDB_API_KEY: "%s"\n' "$TMDB_API_KEY" > "$F"
assert_exit_code 1 "la key real de TMDB presente -> falla" assert_no_third_party_keys "$F"
printf 'x: "%s"\n' "$KINOPOISK_API_KEY" > "$F"
assert_exit_code 1 "la key real de Kinopoisk presente -> falla" assert_no_third_party_keys "$F"
printf 'nada\n' > "$F"
assert_exit_code 0 "MDBLIST_API_KEY vacía no se busca (no hay nada que pueda filtrarse)" assert_no_third_party_keys "$F"
rm -f "$F"

print_summary
exit $?
