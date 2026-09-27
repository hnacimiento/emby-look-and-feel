#!/usr/bin/env bash
# Tests for the config file loader (install-emby-custom.conf): parsing,
# allow-list, type validation, quoting, list splitting. Uses the REAL
# functions and the REAL CONFIG_KEYS/type lists from the script.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/test_helpers.sh
source "$HERE/../lib/test_helpers.sh"
# shellcheck source=../lib/extract_functions.sh
source "$HERE/../lib/extract_functions.sh"

die_precheck() { echo "DIE: $*" >&2; exit 1; }
warn() { echo "  [WARNING] $*"; }
# CONFIG_KEYS (multi-line array) and the type lists, straight from the script.
eval "$(awk '/^CONFIG_KEYS=\(/,/^\)/' "$INSTALLER_SCRIPT")"
eval "$(grep -E '^CONFIG_(BOOL|INT|URL_SLASH)_KEYS=' "$INSTALLER_SCRIPT")"
source_functions config_key_allowed config_validate_value load_config_file config_split_list

write_conf() { local f; f="$(mktemp)"; printf '%s\n' "$@" > "$f"; printf '%s' "$f"; }

suite "allow-list: only documented keys; API keys are rejected"
assert_exit_code 0 "THEME_SET_AS_DEFAULT is allowed" config_key_allowed THEME_SET_AS_DEFAULT
assert_exit_code 1 "TMDB_API_KEY is NOT allowed (secrets live in secrets/api.env)" config_key_allowed TMDB_API_KEY
assert_exit_code 1 "EMBY_API_KEY is NOT allowed" config_key_allowed EMBY_API_KEY
assert_exit_code 1 "JS_URLS (technical constant) is NOT allowed" config_key_allowed JS_URLS
assert_eq "$(grep -c . <<< "$(printf '%s\n' "${CONFIG_KEYS[@]}")")" "${#CONFIG_KEYS[@]}" "CONFIG_KEYS loaded from the script ($(printf '%s' "${#CONFIG_KEYS[@]}") keys)"

suite "every documented key in install-emby-custom.conf.example is allowed and its value valid"
EXAMPLE="$(cd "$HERE/../.." && pwd)/install-emby-custom.conf.example"
F="$(mktemp)"; : > "$F"
BAD=0
while IFS= read -r line; do
    [[ "$line" =~ ^#?([A-Z][A-Z0-9_]*)=\"(.*)\"$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    config_key_allowed "$k" || { echo "  not allowed: $k"; BAD=1; }
    r="$(config_validate_value "$k" "$v")" || { echo "  invalid: $k=$v ($r)"; BAD=1; }
done < "$EXAMPLE"
assert_eq "$BAD" "0" "all keys/values in the example (including commented examples) pass the loader's validation"
rm -f "$F"

suite "load_config_file: happy path, quoting, comments, CRLF, precedence over defaults"
CF="$(write_conf '# comment' '' 'ELSEWHERE_DEFAULT_REGION="AR"' "REVIEWS_MAX_REVIEWS='12'" 'API_PROXY_URL="https://emby.example.com/api-proxy/"   ' $'THEME_SET_AS_DEFAULT="0"\r' 'SPOTLIGHT_PLAYBUTTON_COLOR="hsl(var(--x), 1%, 2%)"')"
ELSEWHERE_DEFAULT_REGION="US"; REVIEWS_MAX_REVIEWS="30"; API_PROXY_URL=""; THEME_SET_AS_DEFAULT="1"; SPOTLIGHT_PLAYBUTTON_COLOR=""
load_config_file "$CF"
assert_eq "$ELSEWHERE_DEFAULT_REGION" "AR" "double-quoted value applied over the default"
assert_eq "$REVIEWS_MAX_REVIEWS" "12" "single-quoted value applied"
assert_eq "$API_PROXY_URL" "https://emby.example.com/api-proxy/" "trailing spaces after the value are ignored"
assert_eq "$THEME_SET_AS_DEFAULT" "0" "CRLF line endings are tolerated"
assert_eq "$SPOTLIGHT_PLAYBUTTON_COLOR" "hsl(var(--x), 1%, 2%)" "parentheses/commas/percent in a free-text value are fine (no shell evaluation)"
rm -f "$CF"

suite "load_config_file: rejects unknown keys, bad types and shell metacharacters"
for bad in 'TMDB_API_KEY="abc"' 'NOT_A_KEY="1"' 'THEME_SET_AS_DEFAULT="yes"' 'REVIEWS_MAX_REVIEWS="ten"' 'CORS_PROXY_URL="https://emby.example.com/cors-proxy"' 'API_PROXY_RESOLVE_IP="nginx.local"' 'ELSEWHERE_DEFAULT_REGION="Argentina"' 'ELSEWHERE_UI_LANGUAGE="fr"' 'SPOTLIGHT_ENABLE_IMDB="1"' 'EMBY_URL="http://emby.example.com/web/"' 'SPOTLIGHT_VIDEO_VOLUME="1.5"' 'SPOTLIGHT_PREFERRED_VIDEO_QUALITY="4k"' 'REVIEWS_PRIMARY_LANGUAGE="$(rm -rf /)"' 'CSS_PIN_REF="`id`"' 'lowercase="x"' 'JUSTTEXT'; do
    CF="$(write_conf "$bad")"
    assert_exit_code 1 "rejected: $bad" load_config_file "$CF"
    rm -f "$CF"
done

suite "load_config_file: the file is parsed, never sourced"
MARK="$(mktemp)"; rm -f "$MARK"
CF="$(write_conf "CSS_PIN_REF=\"\$(touch '$MARK')\"")"
assert_exit_code 1 "a value with \$(...) is rejected" load_config_file "$CF"
assert_eq "$([ -e "$MARK" ] && echo ran || echo not-run)" "not-run" "and the command inside it never ran"
rm -f "$CF" "$MARK"

suite "config_split_list: '|' separated string -> array"
config_split_list L "Netflix|HBO Max|Disney Plus"
assert_eq "${#L[@]}" "3" "three items"
assert_eq "${L[1]}" "HBO Max" "items keep their spaces"
config_split_list L ""
assert_eq "${#L[@]}" "0" "empty string -> empty array (upstream default: show everything)"
config_split_list L ".*with Ads"
assert_eq "${L[0]}" ".*with Ads" "regex patterns pass through untouched"

print_summary
exit $?
