#!/usr/bin/env bash
# Test del payload JSON que arma FASE 8/9 para instalar el CustomCss
# embebiendo el contenido real del CSS (en vez de un '@import url(...)').
# Usa 'node' (si está disponible) para probar la aserción que realmente
# importa: que json_escape produce JSON válido y que decodificarlo devuelve
# el contenido original byte a byte -- no alcanza con mirar el texto del
# payload a ojo, porque un CSS real trae comillas, backslashes y (a veces)
# caracteres no-ASCII que son justo los casos donde un escaping mal hecho
# se nota.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/extract_functions.sh
source "$HERE/../lib/extract_functions.sh"

source_functions json_escape

suite "CustomCss payload -- construcción básica"

CSS_SIMPLE='body { color: red; }'
PAYLOAD="$(printf '{"CustomCss": "%s"}' "$(json_escape "$CSS_SIMPLE")")"
assert_eq "$PAYLOAD" '{"CustomCss": "body { color: red; }"}' "CSS sin caracteres especiales queda igual dentro del payload"

CSS_TRICKY=$'body::before { content: "a \\ b"; }\nfont-family: "It'"'"'s"; /* CRLF test */\r'
PAYLOAD_TRICKY="$(printf '{"CustomCss": "%s"}' "$(json_escape "$CSS_TRICKY")")"
assert_not_contains "$PAYLOAD_TRICKY" "$(printf '\r')" "el \\r crudo no queda suelto en el payload (rompería el JSON de una sola línea)"

suite "leer el archivo preservando el salto de línea final (bug real: rollback disparado en una instalación real)"

# Este es exactamente el bug que causó un rollback innecesario en la
# primera instalación real: 'CSS_CONTENT="$(cat "$archivo")"' recorta
# CUALQUIER salto de línea final, sin importar si el archivo original lo
# tenía. Si además el archivo SÍ termina en salto de línea, lo que se sube
# queda con un byte menos que lo que se hasheó al descargar -- y esa
# diferencia hace fallar la verificación de FASE 9/9 aunque el CSS
# "correcto" se haya instalado perfecto. La corrección real (ver FASE 8/9
# y el bloque de reinstalación de reapply-<timestamp>.sh) usa
# 'IFS= read -r -d ""' en vez de '$(cat ...)' -- eso es lo que se prueba acá.
TMP_WITH_TRAILING_NL="$(mktemp)"
printf 'body { color: red; }\n' > "$TMP_WITH_TRAILING_NL"

BUGGY_READ="$(cat "$TMP_WITH_TRAILING_NL")"
assert_ne "${#BUGGY_READ}" "$(wc -c < "$TMP_WITH_TRAILING_NL" | tr -d ' ')" "'\$(cat archivo)' efectivamente recorta el salto de línea final (reproduce el bug)"

IFS= read -r -d '' FIXED_READ < "$TMP_WITH_TRAILING_NL" || true
assert_eq "${#FIXED_READ}" "$(wc -c < "$TMP_WITH_TRAILING_NL" | tr -d ' ')" "'IFS= read -r -d \"\"' preserva el archivo completo, incluido el salto de línea final"

FIXED_PAYLOAD="$(printf '{"CustomCss": "%s"}' "$(json_escape "$FIXED_READ")")"
EXPECTED_HASH="$(sha256sum "$TMP_WITH_TRAILING_NL" | awk '{print $1}')"
if command -v jq >/dev/null 2>&1; then
    ACTUAL_HASH="$(printf '%s' "$FIXED_PAYLOAD" | jq -j '.CustomCss' | sha256sum | awk '{print $1}')"
    assert_eq "$ACTUAL_HASH" "$EXPECTED_HASH" "round-trip completo (leer -> json_escape -> jq -j) da el mismo hash que el archivo original, con el salto de línea final incluido"
else
    echo "  [skip] jq no disponible localmente: se omite el round-trip completo vía jq -j (SÍ está disponible en el TrueNAS real, ver docs/investigations/)"
fi
rm -f "$TMP_WITH_TRAILING_NL"

if command -v node >/dev/null 2>&1; then
    suite "CustomCss payload -- round-trip exacto vía node (JSON.parse)"

    TMP_CSS="$(mktemp)"
    printf '%s' "$CSS_TRICKY" > "$TMP_CSS"
    IFS= read -r -d '' CSS_CONTENT < "$TMP_CSS" || true
    TMP_PAYLOAD="$(mktemp)"
    printf '{"CustomCss": "%s"}' "$(json_escape "$CSS_CONTENT")" > "$TMP_PAYLOAD"

    # node en Windows no resuelve /tmp/... como Git Bash -- se le pasan las
    # rutas ya convertidas a formato Windows si hace falta.
    WIN_PAYLOAD="$(cygpath -w "$TMP_PAYLOAD" 2>/dev/null || printf '%s' "$TMP_PAYLOAD")"
    WIN_CSS="$(cygpath -w "$TMP_CSS" 2>/dev/null || printf '%s' "$TMP_CSS")"

    NODE_RESULT="$(node -e "
        const fs = require('fs');
        const payload = JSON.parse(fs.readFileSync(String.raw\`$WIN_PAYLOAD\`, 'utf8'));
        const original = fs.readFileSync(String.raw\`$WIN_CSS\`, 'utf8');
        console.log(payload.CustomCss === original ? 'MATCH' : 'MISMATCH');
    " 2>&1)"
    assert_eq "$NODE_RESULT" "MATCH" "CSS con comillas dobles/simples, backslash y CRLF decodifica EXACTO igual al original (round-trip json_escape -> JSON.parse)"
    rm -f "$TMP_CSS" "$TMP_PAYLOAD"
else
    warn_no_node() { echo "  [skip] node no disponible: se omite la verificación de round-trip exacto (json_escape se sigue probando en tests/unit/test_escaping.sh)"; }
    warn_no_node
fi

print_summary
exit $?
