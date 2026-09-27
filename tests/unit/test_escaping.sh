#!/usr/bin/env bash
# Tests unitarios de los helpers de escaping (sección "4. HELPERS DE
# SEGURIDAD / JSON" de install-emby-custom.sh). Cada uno se extrae del
# script real -- ver tests/lib/extract_functions.sh.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/extract_functions.sh
source "$HERE/../lib/extract_functions.sh"

source_functions shell_single_quote json_escape sed_escape_repl sed_escape_pattern grep_escape_ere curl_config_escape http_body_snippet

suite "shell_single_quote"
assert_eq "$(shell_single_quote "simple")" "'simple'" "valor simple queda entre comillas simples"
assert_eq "$(shell_single_quote "it's")" "'it'\\''s'" "comilla simple interna se escapa con el truco '\\''"
assert_eq "$(shell_single_quote "")" "''" "string vacío produce comillas simples vacías"

TMP_ENV="$(mktemp)"
printf 'VALUE=%s\n' "$(shell_single_quote 'a"b$c`d'\''e')" > "$TMP_ENV"
(
    # shellcheck disable=SC1090
    source "$TMP_ENV"
    [ "$VALUE" = 'a"b$c`d'\''e' ]
)
assert_eq "$?" "0" "round-trip vía 'source' preserva comillas dobles, \$, backtick y comilla simple mezclados (uso real: rollback-<ts>.sh generado con EMBY_URL/CONTAINER escapados así)"
rm -f "$TMP_ENV"

suite "json_escape"
assert_eq "$(json_escape 'hello')" 'hello' "texto sin caracteres especiales queda igual"
assert_eq "$(json_escape 'a"b')" 'a\"b' "comilla doble se escapa"
assert_eq "$(json_escape 'a\b')" 'a\\b' "backslash se escapa"
assert_eq "$(json_escape "$(printf 'a\nb')")" 'a\nb' "newline se convierte en \\n literal (payload de CustomCss va en una sola línea JSON)"

suite "sed_escape_repl"
assert_eq "$(sed_escape_repl 'a/b')" 'a\/b' "slash se escapa para el lado derecho de sed s///"
assert_eq "$(sed_escape_repl 'a&b')" 'a\&b' "ampersand se escapa (si no, sed lo interpreta como el match completo)"
assert_eq "$(sed_escape_repl 'a\b')" 'a\\b' "backslash se escapa"

suite "sed_escape_pattern"
assert_eq "$(sed_escape_pattern 'a.b')" 'a\.b' "punto se escapa como literal"
assert_eq "$(sed_escape_pattern 'a*b')" 'a\*b' "asterisco se escapa como literal"
assert_eq "$(sed_escape_pattern 'a[b]')" 'a\[b\]' "corchetes se escapan"
assert_eq "$(sed_escape_pattern 'a/b')" 'a\/b' "slash se escapa (patrón usa / como delimitador de sed)"

suite "grep_escape_ere"
assert_eq "$(grep_escape_ere 'AR')" 'AR' "texto simple sin metacaracteres queda igual"
assert_eq "$(grep_escape_ere '')" '' "string vacío queda vacío -- caso real: CORS_PROXY_URL=\"\" en Spotlight/ratings"
assert_eq "$(grep_escape_ere 'a.b*c')" 'a\.b\*c' "punto y asterisco se escapan"
assert_eq "$(grep_escape_ere '(a|b)')" '\(a\|b\)' "paréntesis y pipe se escapan"

TEST_FILE="$(mktemp)"
printf 'const OTHERVAR = "xARy";\nconst DEFAULT_REGION = "AR";\n' > "$TEST_FILE"
ESCAPED="$(grep_escape_ere "AR")"
if grep -qE "^const DEFAULT_REGION = \"${ESCAPED}\"" "$TEST_FILE"; then
    _test_ok "ancla a la declaración real de DEFAULT_REGION, no a la coincidencia de substring en OTHERVAR"
else
    _test_fail "el anclaje a DEFAULT_REGION no debería haber fallado"
fi
rm -f "$TEST_FILE"

suite "curl_config_escape"
assert_eq "$(curl_config_escape 'plain-token-123')" 'plain-token-123' "token alfanumérico típico (caso común de una API key) queda igual"
assert_eq "$(curl_config_escape 'a"b')" 'a\"b' "comilla doble se escapa (va dentro de header = \"...\")"
assert_eq "$(curl_config_escape 'a\b')" 'a\\b' "backslash se escapa"

suite "http_body_snippet"
TEST_BODY="$(mktemp)"
head -c 500 /dev/zero | tr '\0' 'x' > "$TEST_BODY"
SNIPPET="$(http_body_snippet "$TEST_BODY")"
assert_eq "${#SNIPPET}" "300" "recorta el cuerpo de la respuesta a 300 bytes como mucho"
rm -f "$TEST_BODY"
assert_eq "$(http_body_snippet /no/existe/este/archivo)" "" "archivo inexistente no rompe (curl pudo no haber escrito nada), devuelve vacío"

print_summary
exit $?
