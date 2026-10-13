#!/usr/bin/env bash
# shellcheck disable=SC2034 # the key/HAS_JQ globals are read by the extracted real functions, not here
# Tests for the 1.2.0 additions: CSS header version detection (used to pick
# the archived CSS that matches the installed Emby), the optional-property
# helpers for settings that only newer upstream versions have
# (enableAwards/enableCustomRatings/OMDB_API_KEY), the OMDb proxy rewrite
# and key leak check, and the ratings-data.json validator. Always runs the
# REAL functions extracted from install-emby-custom.sh.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/extract_functions.sh
source "$HERE/../lib/extract_functions.sh"

die_precheck() { echo "DIE: $*" >&2; exit 1; }
source_functions css_header_emby_version count_property_decl sed_escape_repl sed_escape_pattern \
    grep_escape_ere set_or_die_property_string set_or_die_property_raw \
    set_if_property_string set_if_property_raw rewrite_api_base assert_no_third_party_keys json_is_object
eval "$(grep -E "^(API_BASE_OMDB|API_BASE_TMDB|API_KEY_PLACEHOLDER)=['\"]" "$INSTALLER_SCRIPT")"

FIXTURE="$HERE/../fixtures/emby-ratings-2026-09-30-sample.js"
PROXY="https://emby.example.test/api-proxy/"

suite "css_header_emby_version: Emby version from the Embymalism CSS header"
F="$(mktemp)"
printf '/* ===== Embymalism_4.10.1.0 20260929 ===== */\n\n@import url("x");\n' > "$F"
assert_eq "$(css_header_emby_version "$F")" "4.10.1.0" "four-part version from the first line"
printf '/* ===== Embymalism_4.9.5.0 20260710 ===== */\n' > "$F"
assert_eq "$(css_header_emby_version "$F")" "4.9.5.0" "older release"
printf 'body { color: red; }\n' > "$F"
assert_eq "$(css_header_emby_version "$F")" "" "no header -> empty (caller warns, keeps the download)"
rm -f "$F"

suite "set_if_property_*: settings that only newer addon versions have"
F="$(mktemp)"; cp "$FIXTURE" "$F"
set_if_property_raw "$F" "enableAwards" "false"
assert_contains "$(cat "$F")" "enableAwards: false," "existing boolean set, trailing comma kept"
set_if_property_raw "$F" "enableCustomRatings" "false"
assert_contains "$(cat "$F")" "enableCustomRatings: false," "second boolean set"
set_if_property_string "$F" "OMDB_API_KEY" "$API_KEY_PLACEHOLDER"
assert_contains "$(cat "$F")" "OMDB_API_KEY: '$API_KEY_PLACEHOLDER', // Own key" "string set, quote type and comment kept"
assert_exit_code 1 "missing property -> returns 1 and touches nothing" set_if_property_raw "$F" "enableSomethingNew" "true"
BEFORE="$(sha256sum < "$F")"
set_if_property_raw "$F" "enableSomethingNew" "true" || true
assert_eq "$(sha256sum < "$F")" "$BEFORE" "file unchanged when the property does not exist"
rm -f "$F"

suite "OMDb through the API proxy: rewrite and key leak check"
F="$(mktemp)"; cp "$FIXTURE" "$F"
assert_eq "$API_BASE_OMDB" "https://www.omdbapi.com/" "OMDb base as the addon writes it"
N="$(rewrite_api_base "$F" "$API_BASE_OMDB" "${PROXY}omdb/")"
assert_eq "$N" "1" "one OMDb call rewritten"
assert_contains "$(cat "$F")" "'https://emby.example.test/api-proxy/omdb/?i='+encodeURIComponent(imdb)+'&apikey='" "query string intact after the base (nginx strips apikey= and adds the real one)"
assert_eq "$(grep -c 'www.omdbapi.com' "$F")" "0" "no direct OMDb URL left"
OMDB_API_KEY="realomdbkey123"; TMDB_API_KEY=""; MDBLIST_API_KEY=""; KINOPOISK_API_KEY=""
set_if_property_string "$F" "OMDB_API_KEY" "$API_KEY_PLACEHOLDER"
assert_exit_code 0 "placeholder only -> no leak" assert_no_third_party_keys "$F"
set_if_property_string "$F" "OMDB_API_KEY" "$OMDB_API_KEY"
assert_exit_code 1 "real OMDb key in the JS -> refused in proxy mode" assert_no_third_party_keys "$F"
rm -f "$F"

suite "json_is_object: ratings-data.json must be a JSON object"
HAS_JQ=0
F="$(mktemp)"
printf '{}\n' > "$F"; assert_exit_code 0 "{} accepted" json_is_object "$F"
printf '{"movie_27205": {"awards": {"source": "omdb", "schema": 1, "text": "Won 4 Oscars."}}}' > "$F"
assert_exit_code 0 "keyed object accepted" json_is_object "$F"
printf '[1,2]' > "$F"; assert_exit_code 1 "array refused (the addon ignores it)" json_is_object "$F"
printf 'not json' > "$F"; assert_exit_code 1 "garbage refused" json_is_object "$F"
rm -f "$F"

print_summary
