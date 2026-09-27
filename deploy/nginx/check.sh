#!/usr/bin/env bash
# Verifies, from the outside, that the nginx proxies for the Emby addons
# behave as documented: allowed targets answer with the CORS header and get
# cached, everything else is refused. Read-only: only GETs/OPTIONS/POSTs
# that must be rejected. Exit 0 only if every check passes.
#
# Usage:
#   ./deploy/nginx/check.sh https://emby.example.com [--lan-origin http://192.168.1.10:8096] [--from-wan]
#
# The base URL is the public Emby vhost (the one users open). --lan-origin
# is the direct Emby URL on your LAN, used to check that the API proxy also
# accepts calls from a browser that opened Emby by IP.
#
# Session check (auth_request): the API proxy only answers clients that hold
# a valid Emby session cookie -- or that come from a LAN source IP, which
# bypasses it. Run this script from the LAN and the API-proxy calls pass by
# IP; run it from OUTSIDE (mobile data, a VPS) with --from-wan and it
# additionally asserts that a call with the right Referer but no session
# cookie is refused (401). Optionally export EMBY_API_KEY (an Emby API key
# works as a token; it is never printed) to assert that an authenticated
# /emby/ call issues the emby_proxy_token cookie and an invalid token does
# not.
set -Eeuo pipefail

BASE="${1:?usage: $0 https://emby.example.com [--lan-origin http://192.168.1.10:8096] [--from-wan]}"
BASE="${BASE%/}"
LAN_ORIGIN=""; FROM_WAN=0
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --lan-origin) LAN_ORIGIN="${2%/}"; shift 2 ;;
        --from-wan) FROM_WAN=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PLACEHOLDER="via-nginx-api-proxy"
REF="Referer: $BASE/web/index.html"
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# check LABEL EXPECTED_STATUS curl-args...
check() {
    local label="$1" expected="$2"; shift 2
    local status
    status="$(curl -s -m 25 -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' "$@" 2>/dev/null || echo "000")"
    if [ "$status" = "$expected" ]; then
        printf '  [ok]   %-58s %s\n' "$label" "$status"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %-58s got %s, expected %s\n' "$label" "$status" "$expected"; FAIL=$((FAIL + 1))
    fi
}
# Never echo a session token: the cookie value IS the Emby access token.
redact() { sed -E 's/(emby_proxy_token=)[0-9a-f]{32}/\1<redacted>/g'; }
header_is() { # header_is NAME EXPECTED_SUBSTRING LABEL  (on the last response)
    if grep -i "^$1:" "$TMP/headers" | grep -qi -- "$2"; then
        printf '  [ok]   %-58s %s\n' "$3" "$(grep -i "^$1:" "$TMP/headers" | tr -d '\r' | head -1 | redact)"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %-58s header %s: %s\n' "$3" "$1" "$(grep -i "^$1:" "$TMP/headers" | tr -d '\r' | head -1 | redact)"; FAIL=$((FAIL + 1))
    fi
}

echo "== Emby vhost =="
check "Emby web answers" 200 "$BASE/web/index.html"

echo "== Emby session -> cookie (auth_request) =="
check "invalid token on /emby/System/Info -> 401" 401 -H "X-Emby-Token: 00000000000000000000000000000000" "$BASE/emby/System/Info"
if grep -qi '^set-cookie: emby_proxy_token' "$TMP/headers"; then echo "  [FAIL] a 401 response must not issue the session cookie"; FAIL=$((FAIL + 1)); else echo "  [ok]   no session cookie on an invalid token"; PASS=$((PASS + 1)); fi
if [ -n "${EMBY_API_KEY:-}" ]; then
    check "valid token on /emby/System/Info -> 200" 200 -H "X-Emby-Token: $EMBY_API_KEY" "$BASE/emby/System/Info"
    header_is "Set-Cookie" "emby_proxy_token=" "  session cookie issued (Path=/api-proxy/, HttpOnly, Secure, SameSite=Strict)"
    COOKIE="$(grep -i '^set-cookie: emby_proxy_token' "$TMP/headers" | sed -E 's/^[^:]*: *([^;]*).*/\1/' | tr -d '\r')"
    check "API proxy WITH the session cookie -> 200" 200 -H "$REF" -H "Cookie: $COOKIE" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
else
    echo "  [skip] EMBY_API_KEY not exported: cookie issuance / cookie-authenticated call not checked"
fi
if [ "$FROM_WAN" = "1" ]; then
    check "WAN: right Referer but no session cookie -> 401" 401 -H "$REF" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
    check "WAN: bogus session cookie -> 401" 401 -H "$REF" -H "Cookie: emby_proxy_token=00000000000000000000000000000000" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
else
    echo "  [info] running from the LAN: API-proxy calls below pass by source IP; use --from-wan from outside to assert the 401s"
fi

echo "== API proxy (needs snippets/emby-api-proxy.conf + keys) =="
check "TMDB via proxy, same-origin Referer" 200 -H "$REF" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
header_is "Access-Control-Allow-Origin" "*" "  CORS header present"
grep -q '"images"' "$TMP/body" && { echo "  [ok]   TMDB answered with real data (key injected by nginx)"; PASS=$((PASS + 1)); } || { echo "  [FAIL] TMDB body has no \"images\" (key not injected / wrong key?)"; FAIL=$((FAIL + 1)); }
check "TMDB via proxy, repeat" 200 -H "$REF" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
header_is "X-Api-Cache" "HIT" "  second call served from the shared cache"
check "MDBList via proxy" 200 -H "$REF" "$BASE/api-proxy/mdblist/tmdb/movie/27205?apikey=$PLACEHOLDER"
check "Kinopoisk via proxy (header key)" 200 -H "$REF" -H "X-API-KEY: $PLACEHOLDER" "$BASE/api-proxy/kinopoisk/api/v2.2/films?keyword=Inception&yearFrom=2010&yearTo=2010"
check "no Referer/Origin -> 403" 403 "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
check "foreign Referer -> 403" 403 -H "Referer: https://evil.example/" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
check "look-alike domain -> 403" 403 -H "Referer: ${BASE}.evil.example/" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
[ -n "$LAN_ORIGIN" ] && check "LAN Origin ($LAN_ORIGIN) -> 200" 200 -H "Origin: $LAN_ORIGIN" "$BASE/api-proxy/tmdb/3/configuration?api_key=$PLACEHOLDER"
check "OPTIONS preflight -> 204" 204 -X OPTIONS -H "$REF" "$BASE/api-proxy/tmdb/3/configuration"
check "POST -> 405" 405 -X POST -H "$REF" "$BASE/api-proxy/tmdb/3/configuration"
if grep -qiE 'api_key=|apikey=' "$TMP/body"; then echo "  [FAIL] a response body contains an API key parameter"; FAIL=$((FAIL + 1)); else echo "  [ok]   no API key leaks in response bodies"; PASS=$((PASS + 1)); fi

echo "== CORS proxy (snippets/emby-cors-proxy.conf) =="
check "Rotten Tomatoes page via proxy" 200 "$BASE/cors-proxy/https://www.rottentomatoes.com/m/inception"
header_is "Access-Control-Allow-Origin" "*" "  CORS header present"
check "AlloCine page via proxy" 200 "$BASE/cors-proxy/https://www.allocine.fr/film/fichefilm_gen_cfilm=143692.html"
check "merged-slash variant (https:/...)" 200 "$BASE/cors-proxy/https:/www.allocine.fr/film/fichefilm_gen_cfilm=143692.html"
check "TMDB relative redirect rewritten -> 301" 301 "$BASE/cors-proxy/https://www.themoviedb.org/movie/27205/watch?locale=US"
header_is "Location" "$BASE/cors-proxy/https://www.themoviedb.org/" "  Location goes back through the proxy"
check "non-allow-listed host -> 403" 403 "$BASE/cors-proxy/https://example.com/"
check "OPTIONS -> 204" 204 -X OPTIONS "$BASE/cors-proxy/https://www.rottentomatoes.com/m/x"
check "POST -> 405" 405 -X POST "$BASE/cors-proxy/https://www.rottentomatoes.com/m/x"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
