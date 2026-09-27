#!/usr/bin/env bash
# ==============================================================================
# install-emby-custom.sh
#
# Installer (not a repair tool) for custom addons + CSS for Emby on TrueNAS
# SCALE (Docker). Auto-detects which Emby container to use, derives from the
# container itself where its /config lives and which URL it answers on (no
# hardcoded paths or host:port), asks for credentials interactively on first
# use, and downloads/edits/installs 6 JS addons and the CustomCss via API.
#
# Flow: DETECT CONTAINER -> DETECT PATHS/URL -> SECRETS -> VALIDATE ->
#       DOWNLOAD -> EDIT -> BACKUP -> INSTALL -> VERIFY -> ARTIFACTS
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Remembers the Emby container and URL chosen in the previous run, so they
# do not have to be picked again every time. Lives next to the script (it
# does not depend on BASE, which is not known yet at this point).
STATE_FILE="$SCRIPT_DIR/.emby-installer-state"

# ------------------------------------------------------------------------
# -1. COMMAND-LINE ARGUMENTS
# ------------------------------------------------------------------------
#
# All of this is optional: with no arguments, the script behaves as before
# (interactive wizard). With --silent, it NEVER calls 'read': any missing
# piece of data (container, URL, credentials) makes the script exit with an
# error explaining what is missing, instead of waiting for input that will
# never arrive (that is why --discover-only exists: so a user without much
# knowledge of their infrastructure can use the interactive mode ONCE,
# leave everything cached in STATE_FILE, and run --silent from then on
# without having to find anything out by hand).

usage() {
    cat <<'USAGE'
install-emby-custom.sh [options]

  --container=NAME      Use this container without asking (skips the list).
  --emby-url=URL        Use this Emby URL without asking/auto-detecting.
  --silent               Non-interactive: never calls 'read'. Requires
                          --container/--emby-url (or values already cached
                          in .emby-installer-state) and secrets/api.env
                          already created, or EMBY_API_KEY/TMDB_API_KEY (and
                          optionally MDBLIST_API_KEY/KINOPOISK_API_KEY) as
                          environment variables to create it without the
                          wizard.
  --discover-only        Run only the container/BASE/URL detection, save it
                          to .emby-installer-state, and exit without
                          touching credentials, addons or the container.
                          Meant to leave everything ready before a later
                          --silent run.
  --require-known-hashes  Strict supply chain: if a downloaded addon has a
                          SHA256 different from the one of the last
                          successful install, abort instead of just
                          warning. The first time an addon is seen (no
                          previous hash recorded) it never blocks.
  --no-default-theme      Register 'Embymalism' in the Theme combo but do
                          NOT make it the default theme: Dark stays the
                          default and each user picks it by hand. Without
                          this flag (or with THEME_SET_AS_DEFAULT=1 in the
                          script), Embymalism becomes the default theme for
                          every user/device that has not chosen another
                          one. The Settings theme never changes.
  --config=PATH           Config file with your environment/product values
                          (see install-emby-custom.conf.example). Default:
                          install-emby-custom.conf next to this script, if
                          it exists. Precedence: CLI flag > config file >
                          built-in default. Never holds API keys.
  --print-config          Load the config (if any), print every effective
                          value and exit without touching anything.
  --dry-run               Run everything up to and including the addon
                          edits and the index.html/skinmanager.js staging
                          (download, key injection, verification), then
                          stop BEFORE the backup/install phases. Nothing in
                          the container or in Emby's Branding is touched.
  --uninstall             Run the newest rollback-<timestamp>.sh for the
                          detected container (restores index.html,
                          skinmanager.js, the addons and the previous
                          CustomCss) and exit with its result.
  --status                Compare what is inside the container (addons,
                          index.html, skinmanager.js, theme.css, Branding
                          CustomCss) with the last successful install and
                          exit: 0 = everything as installed, 1 = drift
                          (e.g. the container was recreated).
  --check-updates         Download the addons/CSS, compare their hashes with
                          the last successful install, report what changed
                          upstream and exit WITHOUT installing anything.
  --version               Print the script version and exit.
  -h, --help              Print this help.

Examples:
  ./install-emby-custom.sh --discover-only
  ./install-emby-custom.sh --silent --container=ix-emby-emby-1 --emby-url=http://192.168.1.10:8096
  EMBY_API_KEY=... TMDB_API_KEY=... ./install-emby-custom.sh --silent --container=ix-emby-emby-1 --emby-url=http://192.168.1.10:8096
  ./install-emby-custom.sh --config=/path/to/install-emby-custom.conf --silent
  ./install-emby-custom.sh --print-config
USAGE
}

OPT_CONTAINER=""
OPT_EMBY_URL=""
SILENT_MODE=0
DISCOVER_ONLY=0
REQUIRE_KNOWN_HASHES=0
OPT_NO_DEFAULT_THEME=0
OPT_CONFIG_FILE=""
PRINT_CONFIG=0
DRY_RUN=0
UNINSTALL=0
STATUS_ONLY=0
CHECK_UPDATES=0
SCRIPT_VERSION="1.0.0"

for arg in "$@"; do
    case "$arg" in
        --container=*)
            OPT_CONTAINER="${arg#--container=}"
            ;;
        --emby-url=*)
            OPT_EMBY_URL="${arg#--emby-url=}"
            ;;
        --silent|--non-interactive)
            SILENT_MODE=1
            ;;
        --discover-only)
            DISCOVER_ONLY=1
            ;;
        --require-known-hashes)
            REQUIRE_KNOWN_HASHES=1
            ;;
        --no-default-theme)
            OPT_NO_DEFAULT_THEME=1
            ;;
        --config=*)
            OPT_CONFIG_FILE="${arg#--config=}"
            ;;
        --print-config)
            PRINT_CONFIG=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --uninstall)
            UNINSTALL=1
            ;;
        --status)
            STATUS_ONLY=1
            ;;
        --check-updates)
            CHECK_UPDATES=1
            ;;
        --version)
            echo "install-emby-custom.sh $SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------
# 0. BUILT-IN DEFAULTS
# ------------------------------------------------------------------------
#
# Three kinds of values live here:
#   - technical constants (container paths, Emby API endpoints, upstream
#     addon URLs, skinmanager.js anchors): part of the code, not config;
#   - environment values (proxy URLs, LAN IP for the smoke test) and
#     product choices (region, languages, Spotlight/ratings settings):
#     these are DEFAULTS only. The real values come from the config file
#     (install-emby-custom.conf, see install-emby-custom.conf.example and
#     "CONFIG FILE" below) so this script stays free of anything specific
#     to one deployment. Precedence: CLI flag > config file > default.
# CONTAINER, BASE and EMBY_URL are detected/chosen in PHASE 2/9 from what
# 'docker' reports (a config file may pre-set container/URL). API keys are
# never here nor in the config file: they live in secrets/api.env.

DASHBOARD_CONTAINER_DIR="/system/dashboard-ui"
INDEX_CONTAINER_PATH="$DASHBOARD_CONTAINER_DIR/index.html"

# Emby version this script was tested against. If the detected server is
# different, a warning is printed (it does not block) -- see README, section
# "Compatibility and future versions".
TESTED_EMBY_VERSION="4.10.0.40"

# How many installs (backup + log + manifest + hashes + rollback + reapply
# of that run) are kept. The oldest ones are deleted at the end of each
# successful install -- never during a failure, so nothing that might be
# needed for diagnosis is lost.
BACKUP_RETENTION_COUNT=5

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

# The 6 addons. Only those listed in EDITED_JS get key injection.
JS_NAMES=(
    "emby-elsewhere.js"
    "emby-linklogos.js"
    "emby-media-ratings.js"
    "emby-ratings.js"
    "Spotlight.js"
    "Reviews.js"
)

JS_URLS=(
    "https://raw.githubusercontent.com/v1rusnl/Embymalism/main/Addons/emby-elsewhere.js"
    "https://raw.githubusercontent.com/v1rusnl/Embymalism/main/Addons/emby-linklogos.js"
    "https://raw.githubusercontent.com/v1rusnl/Embymalism/main/Addons/emby-media-ratings.js"
    "https://raw.githubusercontent.com/v1rusnl/Embymalism/main/Addons/emby-ratings.js"
    "https://raw.githubusercontent.com/v1rusnl/EmbySpotlight/main/Spotlight.js"
    "https://raw.githubusercontent.com/v1rusnl/EmbyReviews/main/Reviews.js"
)

EDITED_JS=("emby-elsewhere.js" "Spotlight.js" "Reviews.js" "emby-ratings.js")

CSS_NAME="Embymalism.css"
# Empty (default) = always the latest commit of upstream's main branch. A
# commit SHA or tag of github.com/v1rusnl/Embymalism pins the CSS to one
# exact version (--require-known-hashes covers "warn/stop if it changed";
# this is "I want THAT one"). CSS_URL is derived after the config file is
# loaded (see "CONFIG FILE" below).
CSS_PIN_REF=""

# --- Embymalism as a "Theme" combo entry (not as CustomCss) --------------
#
# Emby applies TWO themes: the main one and a "Settings theme" (Light by
# default) for its administration/configuration views. The Branding
# CustomCss is loaded once, globally, regardless of the active theme -- so
# Embymalism (designed for Dark) also overrode the admin panel and made it
# unreadable. Loaded as one more entry of the theme list in
# modules/skinmanager.js, Emby activates it ONLY when the user picks
# "Embymalism" as the main theme, and unloads it when entering a
# configuration view (where the Settings theme rules and stays intact).
#
# The theme list is a hardcoded array literal (AllThemes) with no extension
# point, so the entry is inserted by text, anchored to the start of the
# Light entry (unique in the file). Not a single byte of the existing
# entries or of the default theme is touched: Embymalism is one more option
# each user picks under Preferences -> Display -> Theme. If Emby changes
# skinmanager.js and the anchor disappears, the script does NOT patch and
# falls back to the previous mode (CustomCss) with a warning -- an update
# never leaves the user without a theme (see PHASE 6/9, "Preparing theme").
THEME_ID="embymalism"
THEME_NAME="Embymalism"
# 1 = Embymalism becomes the main theme BY DEFAULT for every user/device
# that has not chosen another one (skinmanager.js recomputes isDefault from
# DefaultTheme; only that default is changed, the Dark entry stays intact
# and remains selectable). 0 = it is only added to the combo and Dark stays
# the default. The --no-default-theme flag forces 0 without editing the
# script. A default theme does not require Emby Premiere to activate; one
# chosen by hand does (Emby's rule, not the script's).
THEME_SET_AS_DEFAULT="1"
SKINMANAGER_REL="modules/skinmanager.js"
SKINMANAGER_CONTAINER_PATH="$DASHBOARD_CONTAINER_DIR/$SKINMANAGER_REL"
THEME_CSS_REL="modules/themes/$THEME_ID/theme.css"
THEME_CSS_CONTAINER_PATH="$DASHBOARD_CONTAINER_DIR/$THEME_CSS_REL"
THEME_ANCHOR='{name:"Light",id:"light",'
# Emby's default: DefaultTheme=(...getPreferredTheme()==="windows"?"windows":null)||"dark".
# With THEME_SET_AS_DEFAULT=1 ONLY that final literal (single occurrence in
# the file) is replaced by our id. The other '||"dark"' in the file (the
# "auto" branch for native apps) is not touched.
THEME_DEFAULT_ANCHOR='"windows":null)||"dark"'
THEME_DEFAULT_PATCHED='"windows":null)||"'"$THEME_ID"'"'
# Same shape as the native entries: reuses the Dark theme stylesheets by
# path (as Blue Radiance/Superman do with darkgradient) and appends ours at
# the end, so it wins the cascade over the base. skipForSettingsthemes
# excludes it from the "Settings theme" combo. Ends with ',' so it can be
# placed right before the Light entry without breaking the array.
THEME_ENTRY='{name:"'"$THEME_NAME"'",id:"'"$THEME_ID"'",controller:DefaultController,infoPath:"modules/themes/dark/theme.json",requires:["cssvariables"],skipForSettingsthemes:!0,stylesheets:[{path:"modules/themes/dark/theme.css",options:{cssvars:!0}},{path:"modules/themes/dark/theme_nontv.css",options:{cssvars:!0,tv:!1}},{path:"modules/themes/dark/theme_tv.css",options:{cssvars:!0,tv:!0}},{path:"'"$THEME_CSS_REL"'",options:{cssvars:!0}}].concat(DarkContentContainerStylesheets)},'

# Default region for emby-elsewhere.js (streaming availability). Upstream
# ships 'US'; set your own ISO 3166-1 country code in the config file so
# the availability shown is yours, not the United States'.
ELSEWHERE_DEFAULT_REGION="US"

# Language of emby-elsewhere.js's user interface. Upstream ships its texts
# in German; "en" (default) and "es" translate them phrase by phrase (see
# "emby-elsewhere.js UI language" in PHASE 6/9), "de" leaves upstream's
# German untouched. Config file value.
ELSEWHERE_UI_LANGUAGE="en"

# Streaming provider filter in emby-elsewhere.js. Empty (default) = ALL
# available providers are shown, which is upstream's factory behavior --
# this only exists to narrow it down without having to hand-edit the
# installed JS (that edit would be lost on the next run, because the addon
# is downloaded and re-injected from scratch every time). Add exact
# provider names (as returned by the API, see the link in the
# DEFAULT_PROVIDERS comment inside emby-elsewhere.js itself) to
# ELSEWHERE_DEFAULT_PROVIDERS to show ONLY those, or patterns (regex
# supported) to ELSEWHERE_IGNORE_PROVIDERS to hide specific ones without
# having to build the full list of the ones you do want to see.
# Examples:
#   ELSEWHERE_DEFAULT_PROVIDERS=("Netflix" "HBO Max" "Disney Plus")
#   ELSEWHERE_IGNORE_PROVIDERS=(".*with Ads" "Some Obscure Regional Service")
ELSEWHERE_DEFAULT_PROVIDERS=()
ELSEWHERE_IGNORE_PROVIDERS=()

# CORS proxy for the 3 addons that support it (Spotlight, emby-ratings,
# emby-elsewhere). It has NOTHING to do with the API keys: it only enables
# the Rotten Tomatoes/AlloCine scraping fallback and Elsewhere's
# "where to watch" deep links (sites without CORS). The addons concatenate
# CORS_PROXY_URL + the full destination URL, hence the trailing slash.
# The proxy is the allowlisted location in deploy/nginx/etc/nginx/snippets/emby-cors-proxy.conf
# (see README, "Reverse proxy"). Empty = feature disabled in all 3.
# Set it in the config file, e.g. "https://emby.example.com/cors-proxy/".
CORS_PROXY_URL=""

# API proxy with shared cache and server-side keys (nginx, see
# deploy/nginx/etc/nginx/snippets/emby-api-proxy.conf). With a value: in the addons the
# bases https://api.mdblist.com/, https://api.themoviedb.org/ and
# https://kinopoiskapiunofficial.tech/ are rewritten to API_PROXY_URL +
# mdblist/ | tmdb/ | kinopoisk/, and instead of the real TMDB/MDBList/
# Kinopoisk keys, API_KEY_PLACEHOLDER is injected (nginx discards it and
# adds the real key). Result: the keys never travel to the browser and the
# responses are cached for every user/device. Empty = previous behavior
# (direct calls with the keys embedded in the JS).
# Set it in the config file, e.g. "https://emby.example.com/api-proxy/".
API_PROXY_URL=""
API_KEY_PLACEHOLDER="via-nginx-api-proxy"
# Smoke-test helper only: if the host running this script cannot reach the
# public IP of the proxy's domain (NAT without hairpin, typical for a NAS),
# curl resolves the proxy host to this LAN IP (--resolve) while keeping the
# domain's SNI/certificate. Empty = normal DNS. Config file value.
API_PROXY_RESOLVE_IP=""
API_BASE_MDBLIST="https://api.mdblist.com/"
API_BASE_TMDB="https://api.themoviedb.org/"
API_BASE_KINOPOISK="https://kinopoiskapiunofficial.tech/"

# Reviews.js language/limits (defaults; override in the config file).
REVIEWS_PRIMARY_LANGUAGE="en-US"
REVIEWS_SECONDARY_LANGUAGE="es-ES"
REVIEWS_MAX_REVIEWS="30"
REVIEWS_PREVIEW_LENGTH="600"
REVIEWS_EXPANDED_BY_DEFAULT="false"
REVIEWS_SHOW_LANGUAGE_FLAGS="true"

# Values for the configurable properties of Spotlight.js (CONFIG.*).
# They are not secrets: they are visible in config.json and in the manifest.
SPOTLIGHT_LIMIT="10"
SPOTLIGHT_AUTOPLAY_INTERVAL="10000"
SPOTLIGHT_VIGNETTE_TOP="#1e1e1e"
SPOTLIGHT_VIGNETTE_BOTTOM="#1e1e1e"
SPOTLIGHT_VIGNETTE_LEFT="#1e1e1e"
SPOTLIGHT_VIGNETTE_RIGHT="#1e1e1e"
SPOTLIGHT_PLAYBUTTON_COLOR='hsl(var(--theme-primary-color-hue), var(--theme-primary-color-saturation), var(--theme-primary-color-lightness))'
SPOTLIGHT_CUSTOM_ITEMS_FILE="spotlight-items.txt"
SPOTLIGHT_ENABLE_VIDEO_BACKDROP="true"
SPOTLIGHT_START_MUTED="false"
SPOTLIGHT_VIDEO_VOLUME="0.4"
SPOTLIGHT_WAIT_FOR_TRAILER_TO_END="true"
# CORRECTION: Spotlight.js ships with enableMobileVideo set to false.
# Unlike the original spec ("verify, do not modify"), here it is actively
# forced to true -- see README, section "Spotlight.js".
SPOTLIGHT_ENABLE_MOBILE_VIDEO="true"
SPOTLIGHT_PREFERRED_VIDEO_QUALITY="hd720"
SPOTLIGHT_ENABLE_SPONSOR_BLOCK="true"
SPOTLIGHT_CACHE_TTL_HOURS="168"
SPOTLIGHT_ENABLE_CUSTOM_RATINGS="true"
SPOTLIGHT_ENABLE_IMDB="true"
SPOTLIGHT_ENABLE_TMDB="true"
SPOTLIGHT_ENABLE_ROTTEN_TOMATOES="true"
SPOTLIGHT_ENABLE_METACRITIC="true"
SPOTLIGHT_ENABLE_TRAKT="true"
SPOTLIGHT_ENABLE_LETTERBOXD="true"
SPOTLIGHT_ENABLE_ROGER_EBERT="true"
SPOTLIGHT_ENABLE_ALLOCINE="true"
SPOTLIGHT_ENABLE_KINOPOISK="true"
SPOTLIGHT_ENABLE_MY_ANIME_LIST="true"
SPOTLIGHT_ENABLE_ANI_LIST="true"

# Values for the configurable properties of emby-ratings.js (CONFIG.*).
# Addon independent from Spotlight, with its own CONFIG block identical in
# shape; without this injection it is installed but shows no rating at all
# (it ships with the 3 API keys empty). They are not secrets except the
# keys, which are taken from secrets/api.env just like in Spotlight.
RATINGS_CACHE_TTL_HOURS="168"
RATINGS_ENABLE_IMDB="true"
RATINGS_ENABLE_TMDB="true"
RATINGS_ENABLE_ROTTEN_TOMATOES="true"
RATINGS_ENABLE_METACRITIC="true"
RATINGS_ENABLE_TRAKT="true"
RATINGS_ENABLE_LETTERBOXD="true"
RATINGS_ENABLE_ROGER_EBERT="true"
RATINGS_ENABLE_ALLOCINE="true"
RATINGS_ENABLE_KINOPOISK="true"
RATINGS_ENABLE_MY_ANIME_LIST="true"
RATINGS_ENABLE_ANI_LIST="true"

# Branding endpoints: reading and writing use different paths in Emby.
EMBY_BRANDING_GET_PATH="/emby/Branding/Configuration"
EMBY_BRANDING_POST_PATH="/System/Configuration/branding"

# ------------------------------------------------------------------------
# 0b. CONFIG FILE (install-emby-custom.conf)
# ------------------------------------------------------------------------
#
# Plain KEY="value" lines, one per line, '#' comments allowed. Only the
# keys listed in CONFIG_KEYS are accepted; anything else is an error (a
# typo must not silently become "default"). Values are validated by type
# before use and never evaluated by the shell: the file is parsed, not
# sourced, so a stray '$(...)' in it cannot run anything. API keys are
# deliberately NOT accepted here -- they belong in secrets/api.env.
#
# List values (ELSEWHERE_*_PROVIDERS) are written as one string with '|'
# between items: ELSEWHERE_IGNORE_PROVIDERS="Foo|Bar with Ads".

CONFIG_KEYS=(
    EMBY_CONTAINER EMBY_URL
    BACKUP_RETENTION_COUNT
    CSS_PIN_REF THEME_SET_AS_DEFAULT
    ELSEWHERE_DEFAULT_REGION ELSEWHERE_UI_LANGUAGE
    ELSEWHERE_DEFAULT_PROVIDERS ELSEWHERE_IGNORE_PROVIDERS
    CORS_PROXY_URL API_PROXY_URL API_PROXY_RESOLVE_IP
    REVIEWS_PRIMARY_LANGUAGE REVIEWS_SECONDARY_LANGUAGE REVIEWS_MAX_REVIEWS
    REVIEWS_PREVIEW_LENGTH REVIEWS_EXPANDED_BY_DEFAULT REVIEWS_SHOW_LANGUAGE_FLAGS
    SPOTLIGHT_LIMIT SPOTLIGHT_AUTOPLAY_INTERVAL SPOTLIGHT_VIGNETTE_TOP
    SPOTLIGHT_VIGNETTE_BOTTOM SPOTLIGHT_VIGNETTE_LEFT SPOTLIGHT_VIGNETTE_RIGHT
    SPOTLIGHT_PLAYBUTTON_COLOR SPOTLIGHT_CUSTOM_ITEMS_FILE
    SPOTLIGHT_ENABLE_VIDEO_BACKDROP SPOTLIGHT_START_MUTED SPOTLIGHT_VIDEO_VOLUME
    SPOTLIGHT_WAIT_FOR_TRAILER_TO_END SPOTLIGHT_ENABLE_MOBILE_VIDEO
    SPOTLIGHT_PREFERRED_VIDEO_QUALITY SPOTLIGHT_ENABLE_SPONSOR_BLOCK
    SPOTLIGHT_CACHE_TTL_HOURS SPOTLIGHT_ENABLE_CUSTOM_RATINGS
    SPOTLIGHT_ENABLE_IMDB SPOTLIGHT_ENABLE_TMDB SPOTLIGHT_ENABLE_ROTTEN_TOMATOES
    SPOTLIGHT_ENABLE_METACRITIC SPOTLIGHT_ENABLE_TRAKT SPOTLIGHT_ENABLE_LETTERBOXD
    SPOTLIGHT_ENABLE_ROGER_EBERT SPOTLIGHT_ENABLE_ALLOCINE SPOTLIGHT_ENABLE_KINOPOISK
    SPOTLIGHT_ENABLE_MY_ANIME_LIST SPOTLIGHT_ENABLE_ANI_LIST
    RATINGS_CACHE_TTL_HOURS
    RATINGS_ENABLE_IMDB RATINGS_ENABLE_TMDB RATINGS_ENABLE_ROTTEN_TOMATOES
    RATINGS_ENABLE_METACRITIC RATINGS_ENABLE_TRAKT RATINGS_ENABLE_LETTERBOXD
    RATINGS_ENABLE_ROGER_EBERT RATINGS_ENABLE_ALLOCINE RATINGS_ENABLE_KINOPOISK
    RATINGS_ENABLE_MY_ANIME_LIST RATINGS_ENABLE_ANI_LIST
)
# Type per key (everything else is free text without shell metacharacters).
CONFIG_BOOL_KEYS=" THEME_SET_AS_DEFAULT REVIEWS_EXPANDED_BY_DEFAULT REVIEWS_SHOW_LANGUAGE_FLAGS SPOTLIGHT_ENABLE_VIDEO_BACKDROP SPOTLIGHT_START_MUTED SPOTLIGHT_WAIT_FOR_TRAILER_TO_END SPOTLIGHT_ENABLE_MOBILE_VIDEO SPOTLIGHT_ENABLE_SPONSOR_BLOCK SPOTLIGHT_ENABLE_CUSTOM_RATINGS SPOTLIGHT_ENABLE_IMDB SPOTLIGHT_ENABLE_TMDB SPOTLIGHT_ENABLE_ROTTEN_TOMATOES SPOTLIGHT_ENABLE_METACRITIC SPOTLIGHT_ENABLE_TRAKT SPOTLIGHT_ENABLE_LETTERBOXD SPOTLIGHT_ENABLE_ROGER_EBERT SPOTLIGHT_ENABLE_ALLOCINE SPOTLIGHT_ENABLE_KINOPOISK SPOTLIGHT_ENABLE_MY_ANIME_LIST SPOTLIGHT_ENABLE_ANI_LIST RATINGS_ENABLE_IMDB RATINGS_ENABLE_TMDB RATINGS_ENABLE_ROTTEN_TOMATOES RATINGS_ENABLE_METACRITIC RATINGS_ENABLE_TRAKT RATINGS_ENABLE_LETTERBOXD RATINGS_ENABLE_ROGER_EBERT RATINGS_ENABLE_ALLOCINE RATINGS_ENABLE_KINOPOISK RATINGS_ENABLE_MY_ANIME_LIST RATINGS_ENABLE_ANI_LIST "
CONFIG_INT_KEYS=" BACKUP_RETENTION_COUNT REVIEWS_MAX_REVIEWS REVIEWS_PREVIEW_LENGTH SPOTLIGHT_LIMIT SPOTLIGHT_AUTOPLAY_INTERVAL SPOTLIGHT_CACHE_TTL_HOURS RATINGS_CACHE_TTL_HOURS "
CONFIG_URL_SLASH_KEYS=" CORS_PROXY_URL API_PROXY_URL "

config_key_allowed() {
    local key="$1" k
    for k in "${CONFIG_KEYS[@]}"; do
        [ "$k" = "$key" ] && return 0
    done
    return 1
}

# Validates one value for one key; prints a reason and returns 1 on error.
config_validate_value() {
    local key="$1" value="$2"
    case "$value" in
        *'$'*|*'`'*|*$'\n'*)
            echo "shell metacharacters (\$, \`) are not allowed"; return 1 ;;
    esac
    if [[ "$CONFIG_BOOL_KEYS" == *" $key "* ]]; then
        case "$key" in
            THEME_SET_AS_DEFAULT)
                [[ "$value" =~ ^[01]$ ]] || { echo "must be 0 or 1"; return 1; } ;;
            *)
                [[ "$value" =~ ^(true|false)$ ]] || { echo "must be true or false"; return 1; } ;;
        esac
    elif [[ "$CONFIG_INT_KEYS" == *" $key "* ]]; then
        [[ "$value" =~ ^[0-9]+$ ]] || { echo "must be a non-negative integer"; return 1; }
    elif [[ "$CONFIG_URL_SLASH_KEYS" == *" $key "* ]]; then
        [ -z "$value" ] || [[ "$value" =~ ^https?://[^[:space:]]+/$ ]] \
            || { echo "must be empty or an http(s) URL ending in '/'"; return 1; }
    else
        case "$key" in
            EMBY_URL)
                [ -z "$value" ] || [[ "$value" =~ ^https?://[^[:space:]/]+(:[0-9]+)?$ ]] \
                    || { echo "must be empty or http(s)://host[:port] with no trailing path"; return 1; } ;;
            API_PROXY_RESOLVE_IP)
                [ -z "$value" ] || [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
                    || { echo "must be empty or an IPv4 address"; return 1; } ;;
            SPOTLIGHT_VIDEO_VOLUME)
                [[ "$value" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || { echo "must be between 0 and 1"; return 1; } ;;
            ELSEWHERE_DEFAULT_REGION)
                [[ "$value" =~ ^[A-Z]{2}$ ]] || { echo "must be a 2-letter ISO country code"; return 1; } ;;
            ELSEWHERE_UI_LANGUAGE)
                [[ "$value" =~ ^(es|en|de)$ ]] || { echo "must be es, en or de"; return 1; } ;;
            SPOTLIGHT_PREFERRED_VIDEO_QUALITY)
                [[ "$value" =~ ^(hd720|hd1080|highres)$ ]] || { echo "must be hd720, hd1080 or highres"; return 1; } ;;
        esac
    fi
    return 0
}

# Parses the file (never sources it) and assigns each allowed key.
load_config_file() {
    local file="$1" line key value lineno=0
    [ -r "$file" ] || die_precheck "Config file $file is not readable."
    if [ "$(stat -c '%a' "$file" 2>/dev/null | tail -c 1)" = "2" ] \
        || [ "$(stat -c '%a' "$file" 2>/dev/null | tail -c 1)" = "6" ] \
        || [ "$(stat -c '%a' "$file" 2>/dev/null | tail -c 1)" = "7" ]; then
        warn "Config file $file is world-writable; anyone on this host could change what gets installed."
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if ! [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            die_precheck "Config file $file line $lineno: expected KEY=\"value\", got: $line"
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        # Strip one pair of surrounding quotes (either kind) and trailing spaces.
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        config_key_allowed "$key" \
            || die_precheck "Config file $file line $lineno: unknown key $key (API keys go in secrets/api.env; see install-emby-custom.conf.example for the accepted keys)."
        local reason
        if ! reason="$(config_validate_value "$key" "$value")"; then
            die_precheck "Config file $file line $lineno: $key $reason."
        fi
        printf -v "$key" '%s' "$value"
    done < "$file"
}

# Pipe-separated string -> bash array (empty string -> empty array).
config_split_list() {
    local __out="$1" str="$2"
    if [ -z "$str" ]; then
        eval "$__out=()"
    else
        local IFS='|'
        # shellcheck disable=SC2206
        eval "$__out=(\$str)"
    fi
}

# The config file is actually loaded right before the banner (section 4b),
# once die_precheck/warn exist; the functions above are just definitions.

# ------------------------------------------------------------------------
# 1. GLOBAL STATE
# ------------------------------------------------------------------------

INSTALL_STARTED=0
ROLLBACK_RUNNING=0
CSS_INSTALL_FAILED=0
CSS_SKIPPED_BY_USER=0

# Failure/recovery state contract (see docs/ARCHITECTURE.md,
# "Failure and exit code contract"). INSTALL_RESULT and ROLLBACK_RESULT are
# the source of truth for deciding the final exit code; they are never
# inferred from rollback()'s return code alone, because a rollback with
# partially failed steps also returns 0 on purpose (it must not re-trigger
# the error trap).
INSTALL_RESULT=""            # SUCCESS | DEGRADED | FAILED
ROLLBACK_RESULT="NOT_NEEDED" # NOT_NEEDED | SUCCESS | PARTIAL | FAILED

# Contract exit codes. "Recovery never improves the exit status": a FAILED
# with ROLLBACK_RESULT=SUCCESS is still EXIT_FAILED, not EXIT_OK.
EXIT_OK=0
EXIT_FAILED=1
EXIT_DEGRADED=2

# ------------------------------------------------------------------------
# 2. LOG BOOTSTRAP
# ------------------------------------------------------------------------
#
# BASE (and therefore the final LOG_FILE) is not known yet -- it is only
# derived from the container in PHASE 2/9. So that nothing that happens
# before that (container selection, URL detection) is lost on screen or in
# the log, logging first goes to a temporary file; once BASE has been
# determined, that content is copied into the final log and logging
# continues there (see "Migrate bootstrap log -> final log").

BOOTSTRAP_LOG="$(mktemp)"
exec > >(tee -a "$BOOTSTRAP_LOG") 2>&1

# ------------------------------------------------------------------------
# 3. LOGGING / ERRORS
# ------------------------------------------------------------------------

log() { echo "$*"; }

section() {
    echo
    echo "=================================================================="
    echo " $*"
    echo "=================================================================="
    echo
}

ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARNING] $*"; }
step() { echo; echo "-- $*"; }

cleanup_temp() {
    # BASE (and everything that depends on it) may not be defined yet if
    # the failure happens before PHASE 2/9 (container selection).
    [ -n "${BASE:-}" ] || return 0

    rm -f \
        "$CUSTOM_ROOT"/*.tmp \
        "$DASHBOARD_UI"/*.tmp \
        "$SOURCE_DIR"/*.tmp \
        "$CUSTOM_ROOT"/branding-*.json.tmp \
        2>/dev/null || true
    # rmdir only removes EMPTY directories: if the backup ended up with
    # real content, this does not touch it; if it was left empty by a
    # failure prior to the backup phase, it is cleaned up so backups/ does
    # not get cluttered.
    rmdir "$BACKUP_DIR" 2>/dev/null || true
}

# rollback: reverts whatever the installation has already modified in the
# container (index.html, addons, CustomCss) using the backup taken in
# PHASE 7/9. Called automatically by die_critical/on_error/on_interrupt
# when INSTALL_STARTED=1. Reentrancy is guarded by ROLLBACK_RUNNING: if a
# command in here failed and fired the error trap again, the rollback is
# not executed a second time.
#
# Leaves the real outcome in ROLLBACK_RESULT (SUCCESS/PARTIAL/FAILED) --
# never in its own return code, which is deliberately kept at 0 so the
# error trap is not fired again from inside the rollback.
# "Rollback finished" and "rollback succeeded" are NOT the same thing, and
# here they are distinguished explicitly instead of assuming success just
# because it was attempted.
rollback() {
    if [ "$ROLLBACK_RUNNING" = "1" ]; then
        return 0
    fi
    ROLLBACK_RUNNING=1

    section "AUTOMATIC ROLLBACK"

    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        echo "WARNING: container $CONTAINER no longer exists; rollback is not possible."
        ROLLBACK_RESULT="FAILED"
        return 0
    fi

    local had_failure=0
    local had_success=0
    local rc

    # The file-by-file restore and the CSS restore are implemented ONCE, in
    # restore_or_warn_file/restore_or_remove_file/restore_css_from_backup
    # (see SHARED_RESTORE_FUNCTIONS above) -- those same definitions are
    # the ones copied verbatim into rollback-<timestamp>.sh and
    # reapply-<timestamp>.sh, so all three rollback paths share the same
    # logic instead of maintaining three independent copies.

    # The 'if' around each call is deliberate, not cosmetic: these
    # functions return 1 (or 2) in expected, handled cases -- if they were
    # called as a simple command ("fn args; rc=\$?"), a non-zero return
    # would trigger this script's 'set -e' mid-loop, exactly the bug from
    # the "|| true" section of docs/ARCHITECTURE.md but one level up (at
    # the call site, not inside the function).

    echo "Restoring index.html..."
    if restore_or_warn_file "$CONTAINER" "$BACKUP_DIR/index.html" "$INDEX_CONTAINER_PATH" "index.html"; then
        had_success=1
    else
        rc=$?
        [ "$rc" = "1" ] && had_failure=1
    fi

    for JS in "${JS_NAMES[@]}"; do
        if restore_or_remove_file "$CONTAINER" "$BACKUP_DIR/$JS" "$DASHBOARD_CONTAINER_DIR/$JS" "$JS"; then
            had_success=1
        else
            rc=$?
            [ "$rc" = "1" ] && had_failure=1
        fi
    done

    echo "Restoring theme $THEME_NAME (skinmanager.js + theme.css)..."
    if restore_or_warn_file "$CONTAINER" "$BACKUP_DIR/skinmanager.js" "$SKINMANAGER_CONTAINER_PATH" "skinmanager.js"; then
        had_success=1
    else
        rc=$?
        [ "$rc" = "1" ] && had_failure=1
    fi
    if restore_or_remove_file "$CONTAINER" "$BACKUP_DIR/theme.css" "$THEME_CSS_CONTAINER_PATH" "theme.css ($THEME_ID)"; then
        had_success=1
    else
        rc=$?
        [ "$rc" = "1" ] && had_failure=1
    fi

    # chmod only what still exists: the addons that were just REMOVED
    # (they did not exist before installing) must not produce a noisy
    # "No such file or directory".
    for path in "$INDEX_CONTAINER_PATH" "$SKINMANAGER_CONTAINER_PATH" "$THEME_CSS_CONTAINER_PATH"; do
        docker exec "$CONTAINER" sh -c "[ ! -f '$path' ] || chmod 644 '$path'" 2>/dev/null || true
    done
    for JS in "${JS_NAMES[@]}"; do
        docker exec "$CONTAINER" sh -c "[ ! -f '$DASHBOARD_CONTAINER_DIR/$JS' ] || chmod 644 '$DASHBOARD_CONTAINER_DIR/$JS'" 2>/dev/null || true
    done

    if [ -f "$BACKUP_DIR/branding-before.json" ]; then
        echo "Restoring Custom CSS..."
        if restore_css_from_backup "$BACKUP_DIR/branding-before.json" "$EMBY_URL" "$EMBY_BRANDING_POST_PATH" "$EMBY_TOKEN_CURL_CONFIG"; then
            had_success=1
        else
            had_failure=1
        fi
    fi

    if [ "$had_failure" = "1" ]; then
        if [ "$had_success" = "1" ]; then
            ROLLBACK_RESULT="PARTIAL"
        else
            ROLLBACK_RESULT="FAILED"
        fi
    else
        ROLLBACK_RESULT="SUCCESS"
    fi

    echo
    echo "Automatic rollback: $ROLLBACK_RESULT"
    echo "Backup used: $BACKUP_DIR"
    return 0
}

# die_precheck: failure before touching anything installed. No rollback
# because there is nothing to revert. Exit contract: always EXIT_FAILED.
die_precheck() {
    INSTALL_RESULT="FAILED"
    section "ERROR (before installation)"
    echo "$1"
    echo
    echo "The container was not modified. Log:"
    echo "  ${LOG_FILE:-$BOOTSTRAP_LOG}"
    cleanup_temp
    exit "$EXIT_FAILED"
}

# die_critical: failure during/after touching the container. Triggers an
# automatic rollback if the installation had already started. Exit
# contract: always EXIT_FAILED, regardless of the rollback outcome --
# recovery never improves the exit status of a failed installation.
die_critical() {
    INSTALL_RESULT="FAILED"
    section "CRITICAL ERROR"
    echo "$1"
    echo
    if [ "$INSTALL_STARTED" = "1" ]; then
        echo "The installation had already started: running automatic rollback."
        rollback || true
    fi
    cleanup_temp
    echo
    echo "Result: INSTALL_RESULT=$INSTALL_RESULT ROLLBACK_RESULT=$ROLLBACK_RESULT"
    echo "Log:"
    echo "  ${LOG_FILE:-$BOOTSTRAP_LOG}"
    exit "$EXIT_FAILED"
}

# on_error: any failure not handled explicitly (ERR trap). Same contract
# as die_critical -- normalized to EXIT_FAILED instead of letting the
# original exit code of the failed command through, so the exit code
# contract is always 0/1/2 and nothing else.
on_error() {
    local original_exit_code=$?
    INSTALL_RESULT="FAILED"
    section "UNHANDLED ERROR"
    echo "Original exit code: $original_exit_code"
    echo "Line: ${BASH_LINENO[0]}"
    if [ "$INSTALL_STARTED" = "1" ]; then
        rollback || true
    fi
    cleanup_temp
    echo
    echo "Result: INSTALL_RESULT=$INSTALL_RESULT ROLLBACK_RESULT=$ROLLBACK_RESULT"
    exit "$EXIT_FAILED"
}

# on_interrupt: Ctrl+C / SIGTERM. If nothing had been mutated yet, it is a
# benign cancellation (EXIT_OK, same as cancelling the wizard). If the
# installation had already started, it is an installation failed by
# interruption: same contract as die_critical.
on_interrupt() {
    echo
    section "CANCELLED BY THE USER"
    if [ "$INSTALL_STARTED" = "1" ]; then
        INSTALL_RESULT="FAILED"
        echo "The installation had already started: running automatic rollback."
        rollback || true
        cleanup_temp
        echo
        echo "Result: INSTALL_RESULT=$INSTALL_RESULT ROLLBACK_RESULT=$ROLLBACK_RESULT"
        exit "$EXIT_FAILED"
    else
        echo "Nothing had been modified yet. No rollback needed."
        cleanup_temp
        exit "$EXIT_OK"
    fi
}

trap on_error ERR
trap on_interrupt INT TERM
trap cleanup_temp EXIT

require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die_precheck "Missing required command: $1"
}

# ------------------------------------------------------------------------
# 4. SAFETY / JSON HELPERS
# ------------------------------------------------------------------------

# Escapes a value so it can be safely embedded in 'KEY=<this>' with single
# quotes, suitable for a later 'source'.
shell_single_quote() {
    local s="$1"
    s=${s//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

# Escapes a value for use as the replacement inside 'sed s/// '.
sed_escape_repl() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//\//\\/}"
    printf '%s' "$s"
}

# Escapes a value for use as the PATTERN (left-hand side) of 'sed s///',
# treating it as literal text instead of a regex.
sed_escape_pattern() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\//\\/}"
    s="${s//./\\.}"
    s="${s//\*/\\*}"
    s="${s//\[/\\[}"
    s="${s//\]/\\]}"
    s="${s//^/\\^}"
    s="${s//\$/\\\$}"
    printf '%s' "$s"
}

mask_len() {
    local s="$1"
    if [ -z "$s" ]; then
        printf '(empty)'
    else
        printf '%s characters' "${#s}"
    fi
}

# Escapes a value for use as LITERAL text inside an ERE pattern (grep -E),
# anchored to a specific line -- prevents the post-edit verification from
# producing a false positive through a substring match anywhere else in
# the file (e.g. a short value like "AR").
grep_escape_ere() {
    local s="$1"
    printf '%s' "$s" | sed -e 's/[][\.^$*+?(){}|]/\\&/g'
}

# ------------------------------------------------------------------------
# Functions shared between this process and the standalone scripts it
# generates (rollback-<timestamp>.sh, reapply-<timestamp>.sh).
#
# They are defined ONCE here, as literal text captured in
# SHARED_RESTORE_FUNCTIONS, and from then on they are used in two ways:
#   1. Via 'eval "$SHARED_RESTORE_FUNCTIONS"' (two lines below), they
#      become available in THIS process -- used by curl_config_escape/
#      http_body_snippet throughout the rest of the script, and by
#      rollback() to restore backups.
#   2. They are inserted verbatim (byte for byte, via
#      "$SHARED_RESTORE_FUNCTIONS" inside an unquoted heredoc) into the
#      body of rollback-<timestamp>.sh and reapply-<timestamp>.sh -- there
#      they are just as standalone as if they had been written by hand in
#      that file (they do not depend on this process at all at runtime),
#      but their source code is THE SAME that runs here, not an
#      independent copy someone has to remember to keep in sync.
#
# Why it matters: docs/ARCHITECTURE.md ("Two rollback paths, same source
# of truth") already documented the risk of having this logic duplicated
# by hand in three places -- and that risk materialized twice: the time
# rollback() was not defined and nobody noticed, and later when the hash
# verification was added without '|| true' in all three places and only
# one was fixed until a later review. Consolidating the source does not
# remove the need for the generated scripts to be standalone, but it does
# remove the need to edit (and to remember to edit) three copies when
# this logic changes.
read -r -d '' SHARED_RESTORE_FUNCTIONS <<'SHARED_RESTORE_FUNCTIONS_EOF' || true
# Escapes a value for insertion inside a JSON string literal. Lives here
# (not as a loose function) because reapply-<timestamp>.sh also builds a
# fresh JSON payload to reinstall the CustomCss (embedding the real CSS
# content, not an @import) and needs the same function.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Escapes a value so it can be embedded in a 'header = "..."' directive of
# a curl config file (-K/--config). Avoids passing API keys as a
# command-line argument (visible via ps//proc while the curl process
# runs).
curl_config_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Returns (on stdout) the first bytes of an HTTP response file, on a
# single line, for inclusion in an error message without dumping the full
# body. Used instead of discarding the response before failing.
http_body_snippet() {
    head -c 300 "$1" 2>/dev/null | tr '\r\n' '  '
}

# Restores a single file from its backup to $dest_path inside the
# container, and confirms by hash that what ended up there is exactly what
# was copied (not just that 'docker cp' returned 0). Returns 0 if it
# restored and verified correctly, 1 if it was attempted and failed, 2 if
# there was no backup (the "warn, do not fail" case -- used by index.html).
restore_or_warn_file() {
    local container="$1" backup_file="$2" dest_path="$3" label="$4"
    if [ ! -f "$backup_file" ]; then
        echo "  WARNING: no backup of $label in $(dirname "$backup_file")."
        return 2
    fi
    if docker cp "$backup_file" "$container:$dest_path"; then
        local restored_hash expected_hash
        restored_hash="$(docker exec "$container" sh -c "sha256sum '$dest_path'" 2>/dev/null | awk '{print $1}' || true)"
        expected_hash="$(sha256sum "$backup_file" | awk '{print $1}')"
        if [ -n "$restored_hash" ] && [ "$restored_hash" = "$expected_hash" ]; then
            echo "  OK restored $label"
            return 0
        else
            echo "  ERROR: $label was copied but the restored hash does not match the backup."
            return 1
        fi
    else
        echo "  ERROR restoring $label"
        return 1
    fi
}

# Same as restore_or_warn_file, but for resources that -- if a backup
# never existed -- must be REMOVED from the container instead of being
# left as they are (the case of the 6 addons: if there was no backup it is
# because they did not exist before installing). Never returns 2: it
# always counts as success or failure.
restore_or_remove_file() {
    local container="$1" backup_file="$2" dest_path="$3" label="$4"
    if [ -f "$backup_file" ]; then
        restore_or_warn_file "$container" "$backup_file" "$dest_path" "$label"
        return $?
    fi
    if docker exec "$container" sh -c "rm -f '$dest_path'" 2>/dev/null; then
        echo "  OK removed $label (did not exist before installing)"
        return 0
    else
        echo "  ERROR removing $label (did not exist before installing)"
        return 1
    fi
}

# Restores the previous CustomCss via the Branding API, using a curl config
# file (-K) already built by the caller (never the key as an argument).
# Prints the real status/body on failure instead of discarding them.
# Returns 0/1.
restore_css_from_backup() {
    local backup_json="$1" emby_url="$2" post_path="$3" token_config="$4"
    local out status
    out="$(mktemp)"
    status="$(
        curl --silent --show-error --location --request POST \
            -K "$token_config" \
            --header "Content-Type: application/json" \
            --header "Accept: application/json" \
            --data-binary "@$backup_json" \
            --output "$out" --write-out '%{http_code}' \
            "$emby_url$post_path" 2>/dev/null || true
    )"
    case "$status" in
        2??)
            echo "  OK Custom CSS restored."
            rm -f "$out"
            return 0
            ;;
        *)
            echo "  ERROR restoring Custom CSS (HTTP ${status:-no response}). Response: $(head -c 300 "$out" 2>/dev/null | tr '\r\n' '  ')"
            echo "  Backup available at: $backup_json"
            rm -f "$out"
            return 1
            ;;
    esac
}
SHARED_RESTORE_FUNCTIONS_EOF

eval "$SHARED_RESTORE_FUNCTIONS"

# ==============================================================================
# 4b. LOAD THE CONFIG FILE, APPLY CLI OVERRIDES, DERIVE VALUES
# ==============================================================================

CONFIG_FILE="${OPT_CONFIG_FILE:-$SCRIPT_DIR/install-emby-custom.conf}"
CONFIG_FILE_USED=""
if [ -n "$OPT_CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ]; then
    # The list keys arrive as strings from the file; the built-in defaults
    # are arrays. Normalize to strings for loading, split afterwards.
    # shellcheck disable=SC2178 # intentional: array default -> string, split back below
    ELSEWHERE_DEFAULT_PROVIDERS="$(IFS='|'; printf '%s' "${ELSEWHERE_DEFAULT_PROVIDERS[*]}")"
    # shellcheck disable=SC2178 # intentional: array default -> string, split back below
    ELSEWHERE_IGNORE_PROVIDERS="$(IFS='|'; printf '%s' "${ELSEWHERE_IGNORE_PROVIDERS[*]}")"
    EMBY_CONTAINER="" EMBY_URL=""
    load_config_file "$CONFIG_FILE"
    CONFIG_FILE_USED="$CONFIG_FILE"
    # shellcheck disable=SC2128 # scalar at this point (reassigned above), not the original array
    config_split_list ELSEWHERE_DEFAULT_PROVIDERS "$ELSEWHERE_DEFAULT_PROVIDERS"
    # shellcheck disable=SC2128 # scalar at this point (reassigned above), not the original array
    config_split_list ELSEWHERE_IGNORE_PROVIDERS "$ELSEWHERE_IGNORE_PROVIDERS"
    # Config-file container/URL are defaults for the CLI flags (CLI wins).
    [ -z "$OPT_CONTAINER" ] && [ -n "${EMBY_CONTAINER:-}" ] && OPT_CONTAINER="$EMBY_CONTAINER"
    [ -z "$OPT_EMBY_URL" ] && [ -n "${EMBY_URL:-}" ] && OPT_EMBY_URL="$EMBY_URL"
fi

# CLI flags override the config file.
[ "$OPT_NO_DEFAULT_THEME" = "1" ] && THEME_SET_AS_DEFAULT="0"

# Values derived from the (now final) configuration.
if [ -n "$CSS_PIN_REF" ]; then
    CSS_URL="https://raw.githubusercontent.com/v1rusnl/Embymalism/$CSS_PIN_REF/Embymalism.css"
else
    CSS_URL="https://raw.githubusercontent.com/v1rusnl/Embymalism/refs/heads/main/Embymalism.css"
fi
SPOTLIGHT_CORS_PROXY_URL="$CORS_PROXY_URL"
RATINGS_CORS_PROXY_URL="$CORS_PROXY_URL"
ELSEWHERE_CORS_PROXY_URL="$CORS_PROXY_URL"

if [ "$PRINT_CONFIG" = "1" ]; then
    echo "# Effective configuration (CLI > ${CONFIG_FILE_USED:-no config file} > built-in defaults)"
    for key in "${CONFIG_KEYS[@]}"; do
        case "$key" in
            EMBY_CONTAINER) printf '%s=%q\n' "$key" "$OPT_CONTAINER" ;;
            EMBY_URL) printf '%s=%q\n' "$key" "$OPT_EMBY_URL" ;;
            ELSEWHERE_DEFAULT_PROVIDERS|ELSEWHERE_IGNORE_PROVIDERS)
                printf '%s=%q\n' "$key" "$(IFS='|'; eval "printf '%s' \"\${${key}[*]}\"")" ;;
            *) printf '%s=%q\n' "$key" "${!key}" ;;
        esac
    done
    echo "# Derived: CSS_URL=$CSS_URL"
    exit 0
fi

# ==============================================================================
# 5. BANNER
# ==============================================================================

section "EMBY CUSTOM ADDONS INSTALLER"

echo "Date:       $(date)"
echo "Mode:       DETECT -> SECRETS -> VALIDATE -> DOWNLOAD -> EDIT -> BACKUP -> INSTALL -> VERIFY"
echo "Log (temporary, until we know where to persist it): $BOOTSTRAP_LOG"

# ==============================================================================
# 6. DEPENDENCIES
# ==============================================================================

section "PHASE 1/9 - Dependencies"

for cmd in bash docker curl grep sed awk sha256sum wc stat date mktemp flock tar; do
    require_cmd "$cmd"
done
ok "Required dependencies present."

HAS_NODE=0
if command -v node >/dev/null 2>&1; then
    HAS_NODE=1
    ok "node available: JS syntax will be validated."
else
    warn "node not available: JS syntax validation skipped."
fi

HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=1
    ok "jq available."
else
    warn "jq not available: plain-text parsing will be used for JSON."
fi

# ==============================================================================
# 7. ENVIRONMENT AUTO-DETECTION
# ==============================================================================
#
# Nothing in CONTAINER/BASE/EMBY_URL is hardcoded: they are chosen/derived
# here from what 'docker' reports about the real system, and saved to
# STATE_FILE so the choice does not have to be repeated on the next run.

section "PHASE 2/9 - Environment auto-detection"

LAST_CONTAINER=""
LAST_EMBY_URL=""
if [ -f "$STATE_FILE" ]; then
    LAST_CONTAINER="$(grep -m1 '^CONTAINER=' "$STATE_FILE" 2>/dev/null | cut -d'=' -f2- || true)"
    LAST_EMBY_URL="$(grep -m1 '^EMBY_URL=' "$STATE_FILE" 2>/dev/null | cut -d'=' -f2- || true)"
fi

CONTAINER=""

if [ -n "$OPT_CONTAINER" ]; then

    step "Container given by --container"

    docker inspect "$OPT_CONTAINER" >/dev/null 2>&1 \
        || die_precheck "No container named '$OPT_CONTAINER' exists (--container)."
    CONTAINER="$OPT_CONTAINER"
    ok "Using $CONTAINER"

elif [ "$SILENT_MODE" = "1" ]; then

    step "Container (--silent, without --container)"

    if [ -n "$LAST_CONTAINER" ] && docker inspect "$LAST_CONTAINER" >/dev/null 2>&1; then
        CONTAINER="$LAST_CONTAINER"
        ok "Reusing cached container: $CONTAINER"
    else
        die_precheck "--silent requires --container=NAME, or a container already cached in $STATE_FILE (run --discover-only first)."
    fi

else

    step "Looking for Emby containers"

    CANDIDATE_NAMES=()
    CANDIDATE_IMAGES=()
    CANDIDATE_STATUSES=()

    while IFS='|' read -r c_name c_image c_status; do
        [ -n "$c_name" ] || continue
        c_lower="$(printf '%s %s' "$c_name" "$c_image" | tr '[:upper:]' '[:lower:]')"
        case "$c_lower" in
            *emby*)
                CANDIDATE_NAMES+=("$c_name")
                CANDIDATE_IMAGES+=("$c_image")
                CANDIDATE_STATUSES+=("$c_status")
                ;;
        esac
    done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || true)

    if [ "${#CANDIDATE_NAMES[@]}" -eq 0 ]; then
        warn "No container with 'emby' in its name or image was found (docker ps -a)."
    else
        echo
        printf '  %-3s %-25s %-35s %s\n' "#" "NAME" "IMAGE" "STATUS"
        for i in "${!CANDIDATE_NAMES[@]}"; do
            printf '  %-3s %-25s %-35s %s\n' \
                "$((i + 1))" "${CANDIDATE_NAMES[$i]}" "${CANDIDATE_IMAGES[$i]}" "${CANDIDATE_STATUSES[$i]}"
        done
        echo
    fi

    while [ -z "$CONTAINER" ]; do
        DEFAULT_HINT=""
        [ -n "$LAST_CONTAINER" ] && DEFAULT_HINT=" [Enter = '$LAST_CONTAINER']"

        CHOICE=""
        READ_OK=1
        read -rp "Container to use (number from the list, or name)$DEFAULT_HINT: " CHOICE || READ_OK=0

        if [ -z "$CHOICE" ] && [ -n "$LAST_CONTAINER" ]; then
            CHOICE="$LAST_CONTAINER"
        fi

        if [ -z "$CHOICE" ]; then
            if [ "$READ_OK" = "0" ]; then
                die_precheck "No answer received (running without an interactive terminal?) and no container is cached in $STATE_FILE."
            fi
            warn "Enter a number from the list or a container name."
            continue
        fi

        CANDIDATE=""
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] \
            && [ "$CHOICE" -ge 1 ] 2>/dev/null \
            && [ "$CHOICE" -le "${#CANDIDATE_NAMES[@]}" ] 2>/dev/null
        then
            CANDIDATE="${CANDIDATE_NAMES[$((CHOICE - 1))]}"
        else
            CANDIDATE="$CHOICE"
        fi

        if docker inspect "$CANDIDATE" >/dev/null 2>&1; then
            CONTAINER="$CANDIDATE"
        else
            warn "No container named '$CANDIDATE' exists (docker inspect failed). Try again."
        fi
    done

fi

CONTAINER_RUNNING="$(docker inspect "$CONTAINER" -f '{{.State.Running}}')"
[ "$CONTAINER_RUNNING" = "true" ] \
    || die_precheck "Container '$CONTAINER' exists but is not running."

CONTAINER_ID="$(docker inspect "$CONTAINER" -f '{{.Id}}')"
CONTAINER_IMAGE="$(docker inspect "$CONTAINER" -f '{{.Config.Image}}')"

ok "Selected container: $CONTAINER (${CONTAINER_ID:0:12}, image: $CONTAINER_IMAGE)"

step "Detecting data path (/config mount)"

BASE="$(
    docker inspect "$CONTAINER" \
        --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}'
)"

[ -n "$BASE" ] \
    || die_precheck "Container '$CONTAINER' has no mount at /config; cannot determine where to persist anything."

ok "BASE detected -> $BASE"

step "Checking write permissions on $BASE"

WRITE_TEST_FILE="$BASE/.install-emby-custom-write-test-$$"
if ! ( : > "$WRITE_TEST_FILE" ) 2>/dev/null; then
    die_precheck "Cannot write to $BASE (/config mount of container '$CONTAINER'). Check permissions/ownership on the host filesystem."
fi
rm -f "$WRITE_TEST_FILE"
ok "$BASE is writable."

step "Acquiring lock (prevents concurrent installs against the same BASE)"

LOCK_FILE="$BASE/.install-emby-custom.lock"
# fd 200 stays open for the whole run; the lock is released automatically
# (by the kernel) when the process ends, no matter how.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    die_precheck "Another install is already in progress for $BASE (lock: $LOCK_FILE). Wait for it to finish. If you are sure none is running (e.g. after a power cut), delete the lock file by hand and retry."
fi
ok "Lock acquired ($LOCK_FILE)."

# 'flock' assumes POSIX locking semantics, which may be unreliable on
# network filesystems (NFS/CIFS/SMB) -- two runs might not exclude each
# other. This only warns: it does not block, because there is no portable
# way to know for certain and BASE may legitimately live on a network
# mount.
BASE_FS_TYPE="$(stat -f -c '%T' "$BASE" 2>/dev/null || true)"
case "$BASE_FS_TYPE" in
    nfs*|cifs|smb*|fuse.*)
        warn "$BASE is on a network filesystem ($BASE_FS_TYPE): 'flock' may not be reliable there to exclude concurrent runs. If you can, run this script against a local mount."
        ;;
esac

# --uninstall: hand over to the newest generated rollback script. It is
# self-contained (own backup lookup, own exit contract: 0 only on a full
# restore), so this wrapper only finds it and reports what it is running.
if [ "$UNINSTALL" = "1" ]; then
    step "Uninstall: locating the newest rollback script"
    LATEST_ROLLBACK="$(find "$CUSTOM_ROOT" -maxdepth 1 -name 'rollback-*.sh' -type f 2>/dev/null | sort | tail -n1 || true)"
    [ -n "$LATEST_ROLLBACK" ] \
        || die_precheck "No rollback-<timestamp>.sh found under $CUSTOM_ROOT: nothing installed by this script to undo (or its artifacts were pruned)."
    ok "Running $LATEST_ROLLBACK"
    echo
    if bash "$LATEST_ROLLBACK"; then
        ok "Uninstall finished: everything restored to the state before that install."
        exit "$EXIT_OK"
    else
        warn "The rollback script reported a partial or failed restore (see above)."
        exit "$EXIT_FAILED"
    fi
fi

# BASE is only known now: build every path that depends on it (these used
# to be fixed constants at the top of the script).
SECRETS_DIR="$BASE/secrets"
SECRETS_FILE="$SECRETS_DIR/api.env"
CUSTOM_ROOT="$BASE/custom"
DASHBOARD_UI="$CUSTOM_ROOT/dashboard-ui"
SOURCE_DIR="$CUSTOM_ROOT/source"
BACKUP_ROOT="$CUSTOM_ROOT/backups"
CONFIG_JSON="$CUSTOM_ROOT/config.json"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
LOG_FILE="$CUSTOM_ROOT/install-$TIMESTAMP.log"
MANIFEST_FILE="$CUSTOM_ROOT/manifest-$TIMESTAMP.json"
HASHES_FILE="$CUSTOM_ROOT/SHA256SUMS-$TIMESTAMP.txt"
TRANSLATION_REPORT="$CUSTOM_ROOT/translation-$TIMESTAMP.txt"
ROLLBACK_FILE="$CUSTOM_ROOT/rollback-$TIMESTAMP.sh"
REAPPLY_FILE="$CUSTOM_ROOT/reapply-$TIMESTAMP.sh"
ORIGINAL_INDEX="$CUSTOM_ROOT/index.html.original"

# Portable backup: a .tgz of the contents of BACKUP_DIR (index.html + the 6
# addons + branding-before.json), next to the script (SCRIPT_DIR, not BASE)
# -- same rationale as .emby-installer-state: something that survives even
# if BASE (the container's /config mount) becomes inaccessible, or if
# custom/backups/ is lost for whatever reason. rollback-<timestamp>.sh knows
# to extract it only when the original backup directory is gone.
BACKUP_TGZ="$SCRIPT_DIR/emby-backup-$TIMESTAMP.tgz"

mkdir -p "$CUSTOM_ROOT" "$DASHBOARD_UI" "$SOURCE_DIR" "$BACKUP_DIR" "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR" 2>/dev/null || true

step "Migrating bootstrap log -> final log"

cat "$BOOTSTRAP_LOG" > "$LOG_FILE" 2>/dev/null || true
rm -f "$BOOTSTRAP_LOG"
chmod 600 "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

ok "Final log: $LOG_FILE"

# Defensive .gitignore: if this folder ever ends up under git, secrets and
# backups must never be committable by accident.
GITIGNORE_FILE="$BASE/.gitignore"
if [ ! -f "$GITIGNORE_FILE" ]; then
    printf 'secrets/\n*.env\nbackups/\n*.log\n' > "$GITIGNORE_FILE"
    chmod 600 "$GITIGNORE_FILE" 2>/dev/null || true
fi

step "dashboard-ui inside the container"

docker exec "$CONTAINER" sh -c "test -s '$INDEX_CONTAINER_PATH'" \
    || die_precheck "$INDEX_CONTAINER_PATH does not exist (or is empty) inside the container."

ok "$INDEX_CONTAINER_PATH present."

step "Detecting Emby URL"

EMBY_URL=""

if [ -n "$OPT_EMBY_URL" ]; then

    STATUS="$(
        curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' \
            --connect-timeout 10 --max-time 20 \
            "$OPT_EMBY_URL/emby/System/Info/Public" 2>/dev/null || true
    )"
    if [ "$STATUS" = "200" ]; then
        EMBY_URL="$OPT_EMBY_URL"
        ok "URL given by --emby-url confirmed: $EMBY_URL"
    else
        die_precheck "The URL given by --emby-url ($OPT_EMBY_URL) did not respond (HTTP ${STATUS:-no response})."
    fi

else

    # 1) automatic attempt: the port the container publishes for 8096/tcp.
    DETECTED_PORT="$(
        docker inspect "$CONTAINER" \
            --format '{{with (index .NetworkSettings.Ports "8096/tcp")}}{{if .}}{{(index . 0).HostPort}}{{end}}{{end}}' \
            2>/dev/null || true
    )"

    if [ -n "$DETECTED_PORT" ]; then
        CANDIDATE_URL="http://127.0.0.1:$DETECTED_PORT"
        STATUS="$(
            curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' \
                --connect-timeout 5 --max-time 10 \
                "$CANDIDATE_URL/emby/System/Info/Public" 2>/dev/null || true
        )"
        if [ "$STATUS" = "200" ]; then
            EMBY_URL="$CANDIDATE_URL"
            ok "Emby auto-detected at $EMBY_URL (published port: $DETECTED_PORT)."
        fi
    fi

    # 2) if auto-detect did not respond, try the URL used last time.
    if [ -z "$EMBY_URL" ] && [ -n "$LAST_EMBY_URL" ]; then
        STATUS="$(
            curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' \
                --connect-timeout 5 --max-time 10 \
                "$LAST_EMBY_URL/emby/System/Info/Public" 2>/dev/null || true
        )"
        if [ "$STATUS" = "200" ]; then
            EMBY_URL="$LAST_EMBY_URL"
            ok "Emby responded at the URL used last time ($EMBY_URL)."
        fi
    fi

    if [ -z "$EMBY_URL" ] && [ "$SILENT_MODE" = "1" ]; then
        die_precheck "--silent requires --emby-url=URL (could not auto-detect, and no cached URL responded)."
    fi

    # 3) if none of the above worked, ask (typical with host networking,
    #    macvlan, or a static IP -- the published port is not enough to know).
    while [ -z "$EMBY_URL" ]; do
        warn "Could not automatically confirm the Emby URL."
        TYPED_URL=""
        read -rp "Emby URL (e.g. http://192.168.1.10:8096): " TYPED_URL \
            || die_precheck "No answer received (running without an interactive terminal?) and the Emby URL could not be confirmed."
        [ -n "$TYPED_URL" ] || continue

        STATUS="$(
            curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' \
                --connect-timeout 10 --max-time 20 \
                "$TYPED_URL/emby/System/Info/Public" 2>/dev/null || true
        )"
        if [ "$STATUS" = "200" ]; then
            EMBY_URL="$TYPED_URL"
            ok "Emby responded at $EMBY_URL"
        else
            warn "No response (HTTP ${STATUS:-no response}). Try again."
        fi
    done

fi

# Atomic write (mktemp + mv) and 600 permissions: in --silent mode this
# file decides which container and which URL get mutated without asking
# -- not a secret, but an authorization/target-selection input, and a
# half-truncated write (crash in the middle of a 'printf > file') must
# not be able to leave it in a partial state that a later --silent run
# would treat as valid.
STATE_TMP="$(mktemp "$SCRIPT_DIR/.emby-installer-state.XXXXXX")"
chmod 600 "$STATE_TMP"
printf 'CONTAINER=%s\nEMBY_URL=%s\n' "$CONTAINER" "$EMBY_URL" > "$STATE_TMP"
mv "$STATE_TMP" "$STATE_FILE"
chmod 600 "$STATE_FILE"
ok "Container and URL saved to $STATE_FILE for the next run."

step "Emby version (compatibility)"

EMBY_INFO_TMP="$(mktemp "$CUSTOM_ROOT/.emby-info.XXXXXX.tmp")"
EMBY_SERVER_VERSION="unknown"

if curl --silent --show-error --location --output "$EMBY_INFO_TMP" \
    --connect-timeout 10 --max-time 20 \
    "$EMBY_URL/emby/System/Info/Public" 2>/dev/null
then
    DETECTED_VERSION="$(grep -oE '"Version":"[^"]*"' "$EMBY_INFO_TMP" | head -n1 | cut -d'"' -f4 || true)"
    [ -n "$DETECTED_VERSION" ] && EMBY_SERVER_VERSION="$DETECTED_VERSION"
fi
rm -f "$EMBY_INFO_TMP"

ok "Emby server: $EMBY_SERVER_VERSION (this script was tested against $TESTED_EMBY_VERSION)"

if [ "$EMBY_SERVER_VERSION" != "unknown" ] && [ "$EMBY_SERVER_VERSION" != "$TESTED_EMBY_VERSION" ]; then
    warn "Your Emby ($EMBY_SERVER_VERSION) differs from the tested one ($TESTED_EMBY_VERSION)."
    warn "The Branding API, the dashboard-ui layout, or the addon format"
    warn "may have changed -- if something fails, that is the first place"
    warn "to look (see README, section 'Compatibility and future versions')."
fi

if [ "$DISCOVER_ONLY" = "1" ]; then
    section "DISCOVERY COMPLETED (--discover-only)"
    echo "Container:  $CONTAINER"
    echo "BASE:       $BASE"
    echo "Emby URL:   $EMBY_URL"
    echo "Emby vers.: $EMBY_SERVER_VERSION"
    echo "Saved to:   $STATE_FILE"
    echo
    echo "No credentials, addons, or the container were touched."
    echo
    echo "To install in silent mode from now on:"
    echo "  ./install-emby-custom.sh --silent --container=$CONTAINER --emby-url=$EMBY_URL"
    echo
    echo "(if secrets/api.env does not exist yet, --silent also needs"
    echo " EMBY_API_KEY and TMDB_API_KEY as environment variables the first time)"
    exit 0
fi

# ==============================================================================
# 8. SECRETS: FIRST-RUN WIZARD OR LOAD EXISTING
# ==============================================================================

section "PHASE 3/9 - Credentials"

if [ -f "$SECRETS_FILE" ]; then

    step "Loading existing credentials"
    ok "$SECRETS_FILE"

elif [ "$SILENT_MODE" = "1" ]; then

    step "First run (--silent): credentials from environment variables"

    [ -n "${EMBY_API_KEY:-}" ] \
        || die_precheck "--silent and $SECRETS_FILE does not exist: missing environment variable EMBY_API_KEY."
    [ -n "${TMDB_API_KEY:-}" ] \
        || die_precheck "--silent and $SECRETS_FILE does not exist: missing environment variable TMDB_API_KEY."

    SECRETS_TMP="$(mktemp "$SECRETS_DIR/.api.env.XXXXXX")"
    chmod 600 "$SECRETS_TMP"

    {
        printf 'EMBY_API_KEY=%s\n'      "$(shell_single_quote "${EMBY_API_KEY}")"
        printf 'TMDB_API_KEY=%s\n'      "$(shell_single_quote "${TMDB_API_KEY}")"
        printf 'MDBLIST_API_KEY=%s\n'   "$(shell_single_quote "${MDBLIST_API_KEY:-}")"
        printf 'KINOPOISK_API_KEY=%s\n' "$(shell_single_quote "${KINOPOISK_API_KEY:-}")"
    } > "$SECRETS_TMP"

    mv "$SECRETS_TMP" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"

    ok "Credentials saved to $SECRETS_FILE (permissions 600), from environment variables."

else

    step "First run: API key setup wizard"
    echo
    echo "$SECRETS_FILE not found."
    echo "We will set up the API keys once. They are stored with"
    echo "permissions 600 and are never shown on screen or in logs."
    echo

    WIZARD_EMBY_API_KEY=""
    while [ -z "$WIZARD_EMBY_API_KEY" ]; do
        read -rsp "EMBY_API_KEY (required): " WIZARD_EMBY_API_KEY \
            || die_precheck "No answer received (running without an interactive terminal?); the credentials wizard cannot be completed."
        echo
        [ -n "$WIZARD_EMBY_API_KEY" ] || echo "  Cannot be empty."
    done

    WIZARD_TMDB_API_KEY=""
    while [ -z "$WIZARD_TMDB_API_KEY" ]; do
        read -rsp "TMDB_API_KEY (required): " WIZARD_TMDB_API_KEY \
            || die_precheck "No answer received (running without an interactive terminal?); the credentials wizard cannot be completed."
        echo
        [ -n "$WIZARD_TMDB_API_KEY" ] || echo "  Cannot be empty."
    done

    read -rsp "MDBLIST_API_KEY (optional, Enter to skip): " WIZARD_MDBLIST_API_KEY
    echo

    read -rsp "KINOPOISK_API_KEY (optional, Enter to skip): " WIZARD_KINOPOISK_API_KEY
    echo

    echo
    echo "Summary (lengths only, never the values):"
    echo "  EMBY_API_KEY      : $(mask_len "$WIZARD_EMBY_API_KEY")"
    echo "  TMDB_API_KEY      : $(mask_len "$WIZARD_TMDB_API_KEY")"
    echo "  MDBLIST_API_KEY   : $(mask_len "$WIZARD_MDBLIST_API_KEY")"
    echo "  KINOPOISK_API_KEY : $(mask_len "$WIZARD_KINOPOISK_API_KEY")"
    echo

    CONFIRM=""
    read -rp "Save these credentials to $SECRETS_FILE? [y/N]: " CONFIRM
    case "$CONFIRM" in
        s|S|si|Si|SI|y|Y|yes|YES)
            ;;
        *)
            echo
            echo "Wizard cancelled by the user. Nothing was saved, Emby was not touched."
            exit 0
            ;;
    esac

    SECRETS_TMP="$(mktemp "$SECRETS_DIR/.api.env.XXXXXX")"
    chmod 600 "$SECRETS_TMP"

    {
        printf 'EMBY_API_KEY=%s\n'      "$(shell_single_quote "$WIZARD_EMBY_API_KEY")"
        printf 'TMDB_API_KEY=%s\n'      "$(shell_single_quote "$WIZARD_TMDB_API_KEY")"
        printf 'MDBLIST_API_KEY=%s\n'   "$(shell_single_quote "$WIZARD_MDBLIST_API_KEY")"
        printf 'KINOPOISK_API_KEY=%s\n' "$(shell_single_quote "$WIZARD_KINOPOISK_API_KEY")"
    } > "$SECRETS_TMP"

    mv "$SECRETS_TMP" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"

    unset WIZARD_EMBY_API_KEY WIZARD_TMDB_API_KEY WIZARD_MDBLIST_API_KEY WIZARD_KINOPOISK_API_KEY

    echo
    ok "Credentials saved to $SECRETS_FILE (permissions 600)."

fi

step "Checking ownership and permissions of $SECRETS_FILE"

# This file is about to be 'source'd: it is not just text, it is executable
# shell. Before that, confirm it belongs to us and nobody else can read it
# -- TrueNAS ACLs that contradict these Unix permission bits are out of
# scope for this check (see ARCHITECTURE.md).
SECRETS_OWNER_UID="$(stat -c '%u' "$SECRETS_FILE" 2>/dev/null || echo -1)"
SECRETS_PERMS="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo '000')"
CURRENT_UID="$(id -u)"

[ "$SECRETS_OWNER_UID" = "$CURRENT_UID" ] \
    || die_precheck "$SECRETS_FILE belongs to UID $SECRETS_OWNER_UID, but this script runs as UID $CURRENT_UID. Refusing to read a credentials file you do not own."

if [ "$SECRETS_PERMS" != "600" ]; then
    warn "$SECRETS_FILE has permissions $SECRETS_PERMS (expected 600) -- check who else can read it on this filesystem."
else
    ok "Ownership and permissions correct (UID $CURRENT_UID, 600)."
fi

# Load (always from the file, never embedded in the script).
# shellcheck disable=SC1090
source "$SECRETS_FILE"

EMBY_API_KEY="${EMBY_API_KEY:-}"
TMDB_API_KEY="${TMDB_API_KEY:-}"
MDBLIST_API_KEY="${MDBLIST_API_KEY:-}"
KINOPOISK_API_KEY="${KINOPOISK_API_KEY:-}"

[ -n "$EMBY_API_KEY" ] || die_precheck "EMBY_API_KEY is empty in $SECRETS_FILE."
[ -n "$TMDB_API_KEY" ] || die_precheck "TMDB_API_KEY is empty in $SECRETS_FILE."

ok "EMBY_API_KEY      : $(mask_len "$EMBY_API_KEY")"
ok "TMDB_API_KEY      : $(mask_len "$TMDB_API_KEY")"
if [ -n "$MDBLIST_API_KEY" ]; then
    ok "MDBLIST_API_KEY   : $(mask_len "$MDBLIST_API_KEY")"
else
    warn "MDBLIST_API_KEY not configured (optional). Spotlight will lose some ratings."
fi
if [ -n "$KINOPOISK_API_KEY" ]; then
    ok "KINOPOISK_API_KEY : $(mask_len "$KINOPOISK_API_KEY")"
else
    warn "KINOPOISK_API_KEY not configured (optional)."
fi

# curl config file (-K) carrying the X-Emby-Token header, so that
# EMBY_API_KEY never appears as a curl command-line argument (visible via
# 'ps'/'/proc/<pid>/cmdline' to any other local user while the process
# runs). TMDB/MDBList/Kinopoisk do go as query parameters -- they are
# low-risk public keys (see README, "Security model"); EMBY_API_KEY is the
# only one handled this way.
EMBY_TOKEN_CURL_CONFIG="$(mktemp "$CUSTOM_ROOT/emby-token-curlrc.XXXXXX.tmp")"
chmod 600 "$EMBY_TOKEN_CURL_CONFIG"
printf 'header = "X-Emby-Token: %s"\n' "$(curl_config_escape "$EMBY_API_KEY")" > "$EMBY_TOKEN_CURL_CONFIG"

# ==============================================================================
# 9. VALIDATE CREDENTIALS AGAINST THE REAL APIS
# ==============================================================================

section "PHASE 4/9 - API key validation"

step "TMDB"

TMDB_TMP="$(mktemp "$CUSTOM_ROOT/.tmdb-response.XXXXXX.tmp")"

TMDB_STATUS="$(
    curl --silent --show-error --location --get \
        --connect-timeout 10 --max-time 30 \
        --data-urlencode "api_key=$TMDB_API_KEY" \
        --output "$TMDB_TMP" --write-out '%{http_code}' \
        "https://api.themoviedb.org/3/authentication" 2>/dev/null || true
)"

if [ "$TMDB_STATUS" != "200" ] || ! grep -qE '"success"[[:space:]]*:[[:space:]]*true' "$TMDB_TMP"; then
    TMDB_ERR_SNIPPET="$(http_body_snippet "$TMDB_TMP")"
    rm -f "$TMDB_TMP"
    die_precheck "TMDB rejected the configured API key (HTTP ${TMDB_STATUS:-no response}). Response: ${TMDB_ERR_SNIPPET:-(empty)}"
fi
rm -f "$TMDB_TMP"
ok "TMDB_API_KEY valid."

step "Emby"

EMBY_BRANDING_TMP="$(mktemp "$CUSTOM_ROOT/.emby-branding.XXXXXX.tmp")"

EMBY_BRANDING_STATUS="$(
    curl --silent --show-error --location \
        --connect-timeout 10 --max-time 30 \
        -K "$EMBY_TOKEN_CURL_CONFIG" \
        --header "Accept: application/json" \
        --output "$EMBY_BRANDING_TMP" --write-out '%{http_code}' \
        "$EMBY_URL$EMBY_BRANDING_GET_PATH" 2>/dev/null || true
)"

if [ "$EMBY_BRANDING_STATUS" != "200" ] || ! grep -q '"CustomCss"' "$EMBY_BRANDING_TMP"; then
    EMBY_ERR_SNIPPET="$(http_body_snippet "$EMBY_BRANDING_TMP")"
    rm -f "$EMBY_BRANDING_TMP"
    die_precheck "The Emby API rejected EMBY_API_KEY or did not return a valid Branding/Configuration (HTTP ${EMBY_BRANDING_STATUS:-no response}). Response: ${EMBY_ERR_SNIPPET:-(empty)}"
fi
rm -f "$EMBY_BRANDING_TMP"
ok "EMBY_API_KEY valid (Branding/Configuration reachable)."

# ==============================================================================
# 10. ADDON AND CSS DOWNLOAD
# ==============================================================================

# --status: read-only comparison of the container with the last successful
# install (its installed-SHA256SUMS.txt + manifest), then exit.
if [ "$STATUS_ONLY" = "1" ]; then
    section "STATUS - container vs. last successful install"
    STATUS_MANIFEST="$(ls -t "$CUSTOM_ROOT"/manifest-*.json 2>/dev/null | head -n1 || true)"
    [ -n "$STATUS_MANIFEST" ] || die_precheck "No manifest found under $CUSTOM_ROOT: nothing was ever installed here by this script."
    STATUS_TS="$(basename "$STATUS_MANIFEST" .json)"; STATUS_TS="${STATUS_TS#manifest-}"
    STATUS_HASHES="$BACKUP_ROOT/$STATUS_TS/installed-SHA256SUMS.txt"
    [ -s "$STATUS_HASHES" ] || die_precheck "Installed hashes of install $STATUS_TS not found ($STATUS_HASHES); cannot compare."
    echo "Last install: $STATUS_TS ($(grep -o '"install_result": "[A-Z_]*"' "$STATUS_MANIFEST" | cut -d'"' -f4)); container $CONTAINER ($CONTAINER_IMAGE)"
    STATUS_DRIFT=0
    status_row() { # label container_path
        local label="$1" path="$2" expected actual
        expected="$(awk -v n="$label" '$2 == n {print $1; exit}' "$STATUS_HASHES")"
        [ -n "$expected" ] || { printf '  %-22s %s\n' "$label" "not part of that install"; return; }
        if ! docker exec "$CONTAINER" sh -c "test -f '$path'" 2>/dev/null; then
            printf '  %-22s MISSING\n' "$label"; STATUS_DRIFT=1; return
        fi
        actual="$(docker exec "$CONTAINER" sh -c "sha256sum '$path'" 2>/dev/null | awk '{print $1}' || true)"
        if [ "$actual" = "$expected" ]; then
            printf '  %-22s OK\n' "$label"
        else
            printf '  %-22s CHANGED (sha256 %s, installed %s)\n' "$label" "${actual:0:12}" "${expected:0:12}"; STATUS_DRIFT=1
        fi
    }
    for JS in "${JS_NAMES[@]}"; do status_row "$JS" "$DASHBOARD_CONTAINER_DIR/$JS"; done
    status_row "index.html" "$INDEX_CONTAINER_PATH"
    status_row "skinmanager.js" "$SKINMANAGER_CONTAINER_PATH"
    status_row "theme.css" "$THEME_CSS_CONTAINER_PATH"
    if docker inspect "$CONTAINER" -f '{{.Id}}' 2>/dev/null | grep -qF "$(grep -o '"container_id": "[0-9a-f]*"' "$STATUS_MANIFEST" | cut -d'"' -f4)"; then
        printf '  %-22s OK (same instance as at install time)\n' "container id"
    else
        printf '  %-22s CHANGED (container recreated since that install)\n' "container id"; STATUS_DRIFT=1
    fi
    STATUS_CSS_TMP="$(mktemp "$CUSTOM_ROOT/.status-css.XXXXXX.tmp")"
    if curl --silent --location --connect-timeout 10 --max-time 20 -K "$EMBY_TOKEN_CURL_CONFIG" \
        --header "Accept: application/json" --output "$STATUS_CSS_TMP" "$EMBY_URL$EMBY_BRANDING_GET_PATH" 2>/dev/null; then
        if [ "$HAS_JQ" = "1" ]; then
            STATUS_CSS_LEN="$(jq -j '.CustomCss // empty' "$STATUS_CSS_TMP" | wc -c | tr -d ' ')"
        else
            STATUS_CSS_LEN="$(wc -c < "$STATUS_CSS_TMP" | tr -d ' ') bytes of JSON"
        fi
        if grep -q '"mode": "theme"' "$STATUS_MANIFEST"; then
            [ "$STATUS_CSS_LEN" = "0" ] && printf '  %-22s OK (empty, theme mode)\n' "Branding CustomCss" \
                || { printf '  %-22s CHANGED (%s chars; expected empty in theme mode)\n' "Branding CustomCss" "$STATUS_CSS_LEN"; STATUS_DRIFT=1; }
        else
            printf '  %-22s %s chars (customcss mode)\n' "Branding CustomCss" "$STATUS_CSS_LEN"
        fi
    else
        printf '  %-22s could not be read\n' "Branding CustomCss"
    fi
    rm -f "$STATUS_CSS_TMP"
    echo
    if [ "$STATUS_DRIFT" = "0" ]; then
        ok "Everything is as installed on $STATUS_TS."
        exit "$EXIT_OK"
    else
        warn "Drift detected: run $CUSTOM_ROOT/reapply-$STATUS_TS.sh (or re-install) to restore."
        exit "$EXIT_FAILED"
    fi
fi

section "PHASE 5/9 - Download"

download_file() {
    local url="$1" dest="$2" label="$3"
    local tmp="$dest.tmp"

    local status
    status="$(
        curl --fail --silent --show-error --location \
            --retry 3 --connect-timeout 15 --max-time 180 \
            --output "$tmp" --write-out '%{http_code}' \
            "$url" 2>/dev/null || true
    )"

    if [ "$status" != "200" ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        die_precheck "Download of $label ($url) failed, HTTP ${status:-no response}."
    fi

    if head -c 2000 "$tmp" | grep -qiE '<!doctype[[:space:]]+html|<html[ >]'; then
        rm -f "$tmp"
        die_precheck "$label looks like an HTML page (404/redirect), not the expected file."
    fi

    mv "$tmp" "$dest"
}

rm -f "$HASHES_FILE"
echo "# SHA256 of downloaded original files ($TIMESTAMP)" >> "$HASHES_FILE"

# "Outdated addon" detection: the freshly downloaded SHA256 is compared
# against the one seen on the last SUCCESSFUL install. If it differs,
# upstream changed the file -- we warn, we do not block (unless
# --require-known-hashes).
#
# KNOWN_HASHES_FILE (the real, already persisted baseline) is read here but
# never overwritten in this phase -- the new hashes accumulate in
# KNOWN_HASHES_NEW (a .tmp, swept by cleanup_temp if the script dies) and
# are only promoted to KNOWN_HASHES_FILE much later, when INSTALL_STARTED
# goes back to 0 after a successful PHASE 9/9. This same logic used to
# truncate KNOWN_HASHES_FILE right here, in the download phase: if the
# install failed afterwards (editing, backup, install), the next
# --require-known-hashes had nothing left to compare the addon that broke
# this run against, because its "last known hash" had already been
# overwritten by a download that never got installed.
KNOWN_HASHES_FILE="$CUSTOM_ROOT/known-source-sha256sums.txt"
KNOWN_HASHES_NEW="$CUSTOM_ROOT/known-source-sha256sums-new.XXXXXX.tmp"
KNOWN_HASHES_NEW="$(mktemp "$KNOWN_HASHES_NEW")"

UPSTREAM_CHANGED=()
UPSTREAM_UNKNOWN=()
check_upstream_change() {
    local name="$1" hash="$2"
    local prev_hash
    prev_hash="$(awk -v n="$name" '$2 == n {print $1; exit}' "$KNOWN_HASHES_FILE" 2>/dev/null || true)"

    if [ -z "$prev_hash" ]; then
        UPSTREAM_UNKNOWN+=("$name")
    elif [ "$prev_hash" != "$hash" ]; then
        UPSTREAM_CHANGED+=("$name")
    fi
    if [ -n "$prev_hash" ] && [ "$prev_hash" != "$hash" ] && [ "$CHECK_UPDATES" != "1" ]; then
        if [ "$REQUIRE_KNOWN_HASHES" = "1" ]; then
            die_precheck "$name changed since your last SUCCESSFUL install (SHA256 differs from $prev_hash) and --require-known-hashes was given: aborting instead of installing an unverified version. Retry without that flag if you trust the change (the new hash is adopted as known only if this install finishes successfully)."
        fi
        warn "$name changed since your last successful install (different SHA256) -- there is a new upstream version."
    fi

    echo "$hash  $name" >> "$KNOWN_HASHES_NEW"
}

for i in "${!JS_NAMES[@]}"; do
    JS="${JS_NAMES[$i]}"
    URL="${JS_URLS[$i]}"
    DEST="$SOURCE_DIR/$JS.original"

    step "$JS"
    download_file "$URL" "$DEST" "$JS"

    SIZE="$(wc -c < "$DEST" | tr -d ' ')"
    [ "$SIZE" -gt 100 ] || die_precheck "$JS was downloaded but is suspiciously small ($SIZE bytes)."

    HASH="$(sha256sum "$DEST" | awk '{print $1}')"
    echo "$HASH  $JS.original" >> "$HASHES_FILE"
    check_upstream_change "$JS" "$HASH"

    ok "Downloaded ($SIZE bytes, sha256 $HASH)"
done

step "$CSS_NAME (audit only, not installed as a file)"
CSS_SOURCE="$SOURCE_DIR/$CSS_NAME.original"
download_file "$CSS_URL" "$CSS_SOURCE" "$CSS_NAME"
CSS_SIZE="$(wc -c < "$CSS_SOURCE" | tr -d ' ')"
[ "$CSS_SIZE" -gt 0 ] || die_precheck "$CSS_NAME was downloaded empty."
CSS_HASH="$(sha256sum "$CSS_SOURCE" | awk '{print $1}')"
echo "$CSS_HASH  $CSS_NAME.original" >> "$HASHES_FILE"
check_upstream_change "$CSS_NAME" "$CSS_HASH"
ok "Downloaded ($CSS_SIZE bytes, sha256 $CSS_HASH)"

# --check-updates: report and stop here. Nothing was edited or installed,
# and the known-hashes baseline is left exactly as it was.
if [ "$CHECK_UPDATES" = "1" ]; then
    section "CHECK UPDATES - upstream vs. last successful install"
    if [ ! -s "$KNOWN_HASHES_FILE" ]; then
        echo "No previous successful install recorded here ($KNOWN_HASHES_FILE): every file counts as new."
    fi
    if [ "${#UPSTREAM_CHANGED[@]}" -gt 0 ]; then
        echo "Changed upstream since the last successful install:"
        for name in "${UPSTREAM_CHANGED[@]}"; do echo "  - $name"; done
    else
        echo "No upstream changes since the last successful install."
    fi
    if [ "${#UPSTREAM_UNKNOWN[@]}" -gt 0 ]; then
        echo "Never installed here before (no hash to compare): ${UPSTREAM_UNKNOWN[*]}"
    fi
    echo
    echo "Downloads kept for inspection under $SOURCE_DIR (*.original). Run without --check-updates to install."
    rm -f "$KNOWN_HASHES_NEW"
    [ "${#UPSTREAM_CHANGED[@]}" -eq 0 ] && exit "$EXIT_OK" || exit "$EXIT_FAILED"
fi

# ==============================================================================
# 11. ADDON EDITING
# ==============================================================================

section "PHASE 6/9 - Addon editing"

# --- JS constant editing helpers ---------------------------------------

# Counts "const|let|var NAME = ..." declarations in a file.
count_const_decl() {
    local file="$1" name="$2"
    grep -cE "^[[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=" "$file" || true
}

# Replaces the value of an existing string constant ('NAME = "..."').
# Fails unless exactly one declaration is found.
set_or_die_const_string() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_const_decl "$file" "$name")"

    [ "$count" = "1" ] || die_precheck "Declaration of $name not found (or ambiguous, x$count) in $(basename "$file")."

    local esc_value
    esc_value="$(sed_escape_repl "$value")"

    sed -i -E \
        "s/^([[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*)([\"'])[^\"']*\3/\1\3${esc_value}\3/" \
        "$file"

    # Verification anchored to the actual declaration (not a whole-file
    # grep): a short value (e.g. a 2-letter region) may appear by
    # coincidence anywhere else in the file, which would make this check
    # pass even if the sed above matched nothing.
    local verify_value
    verify_value="$(grep_escape_ere "$value")"
    grep -qE "^[[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*([\"'])${verify_value}\\2" "$file" \
        || die_precheck "Injection of $name into $(basename "$file") did not verify correctly (the value did not end up in the expected declaration)."
}

# Shared insertion point for consts injected into the same file, so that
# several consecutive injections end up in the order they were called
# (instead of each one being inserted before the previous one). Reset with
# reset_inject_anchor before editing each file.
INJECT_ANCHOR_LINE=""

reset_inject_anchor() {
    INJECT_ANCHOR_LINE=""
}

# Computes (or reuses) the line where a new declaration is inserted.
resolve_inject_anchor_line() {
    local file="$1"

    if [ -n "$INJECT_ANCHOR_LINE" ]; then
        printf '%s' "$INJECT_ANCHOR_LINE"
        return 0
    fi

    local line_no
    line_no="$(grep -nE '^[[:space:]]*(const|let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$file" | head -n1 | cut -d: -f1 || true)"
    [ -n "$line_no" ] || line_no=1

    printf '%s' "$line_no"
}

# Same as the previous one, but if the declaration does not exist it is
# injected as a new line before the first const/let/var declaration of the
# file (or right after the last line injected into this same file).
set_or_inject_const_string() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_const_decl "$file" "$name")"

    if [ "$count" = "1" ]; then
        set_or_die_const_string "$file" "$name" "$value"
        return 0
    fi

    if [ "$count" != "0" ]; then
        die_precheck "Declaration of $name in $(basename "$file") is ambiguous (x$count)."
    fi

    local line_no
    line_no="$(resolve_inject_anchor_line "$file")"

    local esc_value
    esc_value="$(sed_escape_repl "$value")"

    awk -v n="$line_no" -v decl="const ${name} = \"${esc_value}\";" '
        NR == n { print decl }
        { print }
    ' "$file" > "$file.new"
    mv "$file.new" "$file"

    local verify_value
    verify_value="$(grep_escape_ere "$value")"
    grep -qE "^[[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*([\"'])${verify_value}\\2" "$file" \
        || die_precheck "Injection of $name into $(basename "$file") did not verify correctly (the value did not end up in the expected declaration)."

    INJECT_ANCHOR_LINE=$((line_no + 1))
}

# Replaces the value of an existing constant ONLY if it already exists. If
# it does not, it is not added and 1 is returned (silent skip at the caller).
set_if_declared_const_string() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_const_decl "$file" "$name")"

    if [ "$count" = "0" ]; then
        return 1
    fi
    [ "$count" = "1" ] || die_precheck "Declaration of $name in $(basename "$file") is ambiguous (x$count)."

    set_or_die_const_string "$file" "$name" "$value"
    return 0
}

# Numeric/boolean constant ('NAME = 30;' without quotes). Injects if missing.
set_or_inject_const_raw() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_const_decl "$file" "$name")"

    if [ "$count" = "1" ]; then
        sed -i -E \
            "s/^([[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*)[^;]+;/\1${value};/" \
            "$file"
    elif [ "$count" = "0" ]; then
        local line_no
        line_no="$(resolve_inject_anchor_line "$file")"
        awk -v n="$line_no" -v decl="const ${name} = ${value};" '
            NR == n { print decl }
            { print }
        ' "$file" > "$file.new"
        mv "$file.new" "$file"
        INJECT_ANCHOR_LINE=$((line_no + 1))
    else
        die_precheck "Declaration of $name in $(basename "$file") is ambiguous (x$count)."
    fi

    grep -qE "^[[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*${value}[[:space:]]*;" "$file" \
        || die_precheck "$name in $(basename "$file") did not end up as $value after editing."
}

# Builds a JS array literal ["a", "b"] from a bash array, escaping each
# element as a JSON/JS string. Empty array -> "[]".
js_string_array_literal() {
    local -n _arr_ref="$1"
    if [ "${#_arr_ref[@]}" -eq 0 ]; then
        printf '[]'
        return 0
    fi
    local out="[" first=1 item
    for item in "${_arr_ref[@]}"; do
        if [ "$first" = "1" ]; then
            first=0
        else
            out="$out, "
        fi
        out="$out\"$(json_escape "$item")\""
    done
    printf '%s]' "$out"
}

# Same as set_or_inject_const_raw, but for a value that is an array literal
# ('NAME = [...];') instead of a bare number/boolean -- an array contains
# brackets, which are ERE metacharacters, so the subsequent verification
# needs to escape the whole value (grep_escape_ere) before anchoring it in
# the pattern, which set_or_inject_const_raw does not do because it was
# never needed for its values (always numbers/true/false).
set_or_inject_const_array_raw() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_const_decl "$file" "$name")"

    local esc_value
    esc_value="$(sed_escape_repl "$value")"

    if [ "$count" = "1" ]; then
        sed -i -E \
            "s/^([[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*)[^;]+;/\1${esc_value};/" \
            "$file"
    elif [ "$count" = "0" ]; then
        local line_no
        line_no="$(resolve_inject_anchor_line "$file")"
        awk -v n="$line_no" -v decl="const ${name} = ${value};" '
            NR == n { print decl }
            { print }
        ' "$file" > "$file.new"
        mv "$file.new" "$file"
        INJECT_ANCHOR_LINE=$((line_no + 1))
    else
        die_precheck "Declaration of $name in $(basename "$file") is ambiguous (x$count)."
    fi

    local verify_value
    verify_value="$(grep_escape_ere "$value")"
    grep -qE "^[[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*${verify_value}[[:space:]]*;" "$file" \
        || die_precheck "$name in $(basename "$file") did not end up with the expected value after editing."
}

# 'Verify': if the constant exists, normalize it to the expected value. If
# it does not exist, only warn (do not inject) -- per the spec, this group
# is 'verified', not 'injected if missing'.
verify_or_warn_const_raw() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_const_decl "$file" "$name")"

    if [ "$count" = "0" ]; then
        warn "$name does not exist in $(basename "$file"); expected $value. Not injecting ('verify' rule)."
        return 0
    fi
    [ "$count" = "1" ] || die_precheck "Declaration of $name in $(basename "$file") is ambiguous (x$count)."

    if grep -qE "^[[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*${value}[[:space:]]*;" "$file"; then
        ok "$name is already $value in $(basename "$file")."
    else
        sed -i -E \
            "s/^([[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*)[^;]+;/\1${value};/" \
            "$file"
        grep -qE "^[[:space:]]*(const|let|var)[[:space:]]+${name}[[:space:]]*=[[:space:]]*${value}[[:space:]]*;" "$file" \
            || die_precheck "Could not normalize $name to $value in $(basename "$file")."
        ok "$name corrected to $value in $(basename "$file")."
    fi
}

assert_no_placeholder() {
    local file="$1"
    shift
    local ph
    for ph in "$@"; do
        if grep -qF "$ph" "$file"; then
            die_precheck "$(basename "$file") still contains the unreplaced placeholder '$ph'."
        fi
    done
}

# Rewrites ALL occurrences of an API URL base in an addon with the proxy's,
# and verifies that none of the original remain and that the new one
# appears at least as many times as there were. Fails loudly if the base
# does not exist (upstream changed the API URL: API_BASE_* must be
# updated), just like the constant injections.
rewrite_api_base() {
    local file="$1" from="$2" to="$3"
    local before after_from after_to esc_from esc_to
    # '|| true' inside each pipeline: 'grep -o' returns 1 when there are no
    # occurrences (the expected case for after_from), and with pipefail +
    # this script's ERR trap that would abort the install mid-function
    # even though the result is precisely the correct one.
    before="$({ grep -o -F -- "$from" "$file" || true; } | wc -l | tr -d ' ')"
    [ "$before" -gt 0 ] || die_precheck "$(basename "$file"): base $from not found (did upstream change the API URL?)."
    esc_from="$(sed_escape_pattern "$from")"
    esc_to="$(sed_escape_repl "$to")"
    sed -i "s/${esc_from}/${esc_to}/g" "$file"
    after_from="$({ grep -o -F -- "$from" "$file" || true; } | wc -l | tr -d ' ')"
    after_to="$({ grep -o -F -- "$to" "$file" || true; } | wc -l | tr -d ' ')"
    [ "$after_from" = "0" ] && [ "$after_to" -ge "$before" ] \
        || die_precheck "$(basename "$file"): rewrite of $from -> $to ended up inconsistent ($after_from remaining, $after_to new, $before expected)."
    printf '%s' "$before"
}

# In API proxy mode, no REAL third-party key may remain in an addon (only
# the placeholder). Keys are passed via process substitution, never as an
# argument (they do not show up in 'ps').
assert_no_third_party_keys() {
    local file="$1" key name
    for name in TMDB_API_KEY MDBLIST_API_KEY KINOPOISK_API_KEY; do
        key="${!name:-}"
        [ -n "$key" ] || continue
        if grep -qF -f <(printf '%s\n' "$key") "$file"; then
            die_precheck "SECURITY: the real value of $name appears in $(basename "$file") despite API proxy mode. Install aborted."
        fi
    done
}

assert_no_emby_key() {
    local file="$1"
    if grep -q "EMBY_API_KEY" "$file"; then
        die_precheck "SECURITY: EMBY_API_KEY appears in $(basename "$file"). Install aborted."
    fi
    # Also check the VALUE, not just the variable name: the check above
    # only proves the identifier "EMBY_API_KEY" is absent, not that the
    # secret itself did not end up written into the file through some
    # other path (e.g. a future edit that misuses this variable). Today no
    # injection helper references EMBY_API_KEY, so this should never fire
    # -- it is defense in depth for when that stops being true.
    if [ -n "$EMBY_API_KEY" ] && grep -qF -- "$EMBY_API_KEY" "$file"; then
        die_precheck "SECURITY: the value of EMBY_API_KEY appears in $(basename "$file"). Install aborted."
    fi
}

validate_js_syntax() {
    local file="$1"
    [ "$HAS_NODE" = "1" ] || return 0
    node -c "$file" >/dev/null 2>&1 \
        || die_precheck "$(basename "$file") has a JavaScript syntax error (node -c)."
}

# --- Embymalism theme helpers for modules/skinmanager.js -------------------
#
# They work on the whole file in memory with bash substitution (the file is
# a ~15 KB minified JS, in practice a single line: line-based sed/awk are
# useless). Patterns ALWAYS go quoted inside ${var//"pat"/"rep"}:
# THEME_ENTRY/THEME_ANCHOR contain '[', ']', '!' and '*', which unquoted
# would be glob metacharacters for bash.

# Counts literal (fixed-string) occurrences of $2 in file $1.
theme_count_literal() {
    local file="$1" needle="$2"
    # '|| true': 'grep -o' returns 1 with no occurrences (a valid result,
    # "0"); with pipefail + ERR trap that would abort the script.
    { grep -o -F -- "$needle" "$file" 2>/dev/null || true; } | wc -l | tr -d ' '
}

# Removes our entry (if present) and undoes the default-theme change (if
# present), leaving the file as Emby ships it. Idempotent: with nothing of
# ours present, it does not change a byte. Always reverts BOTH things,
# regardless of THEME_SET_AS_DEFAULT: the container's file may come from a
# previous install run with the other option.
theme_strip_entry() {
    local file="$1" content
    IFS= read -r -d '' content < "$file" || true
    content="${content//"$THEME_ENTRY"/}"
    content="${content//"$THEME_DEFAULT_PATCHED"/"$THEME_DEFAULT_ANCHOR"}"
    printf '%s' "$content" > "$file"
}

# Inserts our entry right before the anchor (the Light entry) and, with
# THEME_SET_AS_DEFAULT=1, changes the default theme. Returns 1 (without
# touching the file) if any anchor is not present exactly once or if
# something of ours is already present -- the caller decides whether that
# is fatal or whether to fall back to CustomCss mode.
theme_inject_entry() {
    local file="$1" content
    [ "$(theme_count_literal "$file" "$THEME_ANCHOR")" = "1" ] || return 1
    [ "$(theme_count_literal "$file" "$THEME_ENTRY")" = "0" ] || return 1
    if [ "$THEME_SET_AS_DEFAULT" = "1" ]; then
        [ "$(theme_count_literal "$file" "$THEME_DEFAULT_ANCHOR")" = "1" ] || return 1
        [ "$(theme_count_literal "$file" "$THEME_DEFAULT_PATCHED")" = "0" ] || return 1
    fi
    IFS= read -r -d '' content < "$file" || true
    content="${content/"$THEME_ANCHOR"/"$THEME_ENTRY$THEME_ANCHOR"}"
    if [ "$THEME_SET_AS_DEFAULT" = "1" ]; then
        content="${content/"$THEME_DEFAULT_ANCHOR"/"$THEME_DEFAULT_PATCHED"}"
    fi
    printf '%s' "$content" > "$file"
}

# Verifies that the file ended up EXACTLY as expected after injecting: the
# entry exactly once, the anchor exactly once, both adjacent (the entry
# immediately before the anchor), and the default theme in the state that
# THEME_SET_AS_DEFAULT asks for (changed, or untouched). Returns 0/1.
theme_verify_patched() {
    local file="$1"
    [ "$(theme_count_literal "$file" "$THEME_ENTRY")" = "1" ] || return 1
    [ "$(theme_count_literal "$file" "$THEME_ANCHOR")" = "1" ] || return 1
    [ "$(theme_count_literal "$file" "$THEME_ENTRY$THEME_ANCHOR")" = "1" ] || return 1
    if [ "$THEME_SET_AS_DEFAULT" = "1" ]; then
        [ "$(theme_count_literal "$file" "$THEME_DEFAULT_PATCHED")" = "1" ] || return 1
        [ "$(theme_count_literal "$file" "$THEME_DEFAULT_ANCHOR")" = "0" ] || return 1
    else
        [ "$(theme_count_literal "$file" "$THEME_DEFAULT_PATCHED")" = "0" ] || return 1
        [ "$(theme_count_literal "$file" "$THEME_DEFAULT_ANCHOR")" = "1" ] || return 1
    fi
    return 0
}

# --- Object PROPERTY editing helpers (Spotlight.js) ---------------------
#
# Spotlight.js does not declare its configuration as 'const NAME = ...;',
# but as properties of a CONFIG object: 'NAME: value,' (sometimes with a
# '// ...' comment at the end of the line). These helpers preserve both the
# trailing comma (if any) and that comment.

count_property_decl() {
    local file="$1" name="$2"
    grep -cE "^[[:space:]]*${name}[[:space:]]*:" "$file" || true
}

# String property: NAME: 'value', or NAME: "value", -- keeps the original
# quote type and any trailing comma/comment on the line.
set_or_die_property_string() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_property_decl "$file" "$name")"

    [ "$count" = "1" ] || die_precheck "Property $name not found (or ambiguous, x$count) in $(basename "$file")."

    local esc_value
    esc_value="$(sed_escape_repl "$value")"

    sed -i -E \
        "s/^([[:space:]]*${name}[[:space:]]*:[[:space:]]*)(['\"])[^'\"]*\2(.*)\$/\1\2${esc_value}\2\3/" \
        "$file"

    local verify_value
    verify_value="$(grep_escape_ere "$value")"
    grep -qE "^[[:space:]]*${name}[[:space:]]*:[[:space:]]*(['\"])${verify_value}\\1" "$file" \
        || die_precheck "Injection of $name into $(basename "$file") did not verify correctly (the value did not end up in the expected property)."
}

# Numeric/boolean property: NAME: 30, or NAME: true -- keeps trailing comma
# and end-of-line comment.
set_or_die_property_raw() {
    local file="$1" name="$2" value="$3"
    local count
    count="$(count_property_decl "$file" "$name")"

    [ "$count" = "1" ] || die_precheck "Property $name not found (or ambiguous, x$count) in $(basename "$file")."

    sed -i -E \
        "s/^([[:space:]]*${name}[[:space:]]*:[[:space:]]*)[^,]*(,?)(.*)\$/\1${value}\2\3/" \
        "$file"

    grep -qE "^[[:space:]]*${name}[[:space:]]*:[[:space:]]*${value}[[:space:]]*,?" "$file" \
        || die_precheck "$name in $(basename "$file") did not end up as $value after editing."
}

# --- emby-elsewhere.js UI language (German -> Spanish / English, or none) --
#
# Upstream emby-elsewhere.js ships its user-facing texts (titles, buttons,
# messages) in German. ELSEWHERE_UI_LANGUAGE (config file) selects what to
# do with them:
#   es  = translate to Spanish (table below)
#   en  = translate to English (table below)
#   de  = leave upstream's German untouched (no edit, no audit)
# Translation is done per WHOLE PHRASE (never word by word) so partial
# matches and sentence meaning are not broken. Order matters: longer
# phrases come before shorter ones that are substrings of them (e.g.
# "Anbieter (leer = ...)" before the bare "Anbieter"), so nothing gets cut
# halfway. The German side of each pair is a literal matched against the
# upstream file and must stay byte-identical to upstream.

ELSEWHERE_TR_DE=()
ELSEWHERE_TR_ES=()
ELSEWHERE_TR_EN=()

# add_translation 'German phrase' 'Spanish rendering' 'English rendering'
add_translation() {
    ELSEWHERE_TR_DE+=("$1")
    ELSEWHERE_TR_ES+=("$2")
    ELSEWHERE_TR_EN+=("$3")
}

# Settings modal
add_translation 'Streaming-Einstellungen' 'Configuración de streaming' 'Streaming settings'
add_translation 'Standard-Suchland' 'País de búsqueda predeterminado' 'Default search country'
add_translation 'Weitere Länder durchsuchen (leer = nur Standard)' 'Buscar en más países (vacío = solo el predeterminado)' 'Search more countries (empty = default only)'
add_translation 'Anbieter (leer = alle anzeigen)' 'Proveedores (vacío = mostrar todos)' 'Providers (empty = show all)'
add_translation 'Land hinzufügen...' 'Agregar país...' 'Add country...'
add_translation 'Anbieter hinzufügen...' 'Agregar proveedor...' 'Add provider...'
add_translation 'Abbrechen' 'Cancelar' 'Cancel'
add_translation 'Speichern' 'Guardar' 'Save'
add_translation 'Einstellungen' 'Configuración' 'Settings'
add_translation 'Schließen' 'Cerrar' 'Close'
add_translation 'Auf JustWatch ansehen' 'Ver en JustWatch' 'View on JustWatch'
add_translation 'Anbieter' 'Proveedor' 'Provider'

# Availability per region (the ${...} placeholders are kept intact)
add_translation 'Nicht verfügbar in ${regionName}' 'No disponible en ${regionName}' 'Not available in ${regionName}'
add_translation 'Auch verfügbar in ${regionName} auf:' 'También disponible en ${regionName}:' 'Also available in ${regionName} on:'
add_translation 'Zum Leihen/Kaufen in ${regionName} auf:' 'Para alquilar o comprar en ${regionName}:' 'Rent or buy in ${regionName} on:'
add_translation 'Zum Leihen in ${regionName} auf:' 'Para alquilar en ${regionName}:' 'Rent in ${regionName} on:'
add_translation 'Zum Kaufen in ${regionName} auf:' 'Para comprar en ${regionName}:' 'Buy in ${regionName} on:'
add_translation 'Verfügbar in ${regionName} auf:' 'Disponible en ${regionName}:' 'Available in ${regionName} on:'
add_translation 'Nicht auf Streaming-Diensten in ${regionName} verfügbar' 'No disponible en servicios de streaming en ${regionName}' 'Not available on streaming services in ${regionName}'
add_translation 'Nicht auf Streaming-Diensten in ${regionText} verfügbar' 'No disponible en servicios de streaming en ${regionText}' 'Not available on streaming services in ${regionText}'
add_translation 'Nicht auf Streaming-Diensten verfügbar' 'No disponible en servicios de streaming' 'Not available on streaming services'
add_translation 'Keine konfigurierten Dienste verfügbar' 'No hay servicios configurados disponibles' 'No configured services available'
add_translation 'Keine Streaming-Dienste in ausgewählten Regionen verfügbar' 'No hay servicios de streaming disponibles en las regiones seleccionadas' 'No streaming services available in the selected regions'

# Rent/buy badge tooltips
add_translation 'Zum Leihen' 'Para alquilar' 'To rent'
add_translation 'Zum Kaufen' 'Para comprar' 'To buy'

# Error / status messages
add_translation 'Bitte TMDB API Key im Script eintragen' 'Ingresá tu API key de TMDB en el script' 'Please set the TMDB API key in the script'
add_translation 'Fehler beim Parsen der Antwort' 'Error al procesar la respuesta' 'Error parsing the response'
add_translation 'API Fehler: ${response.status}' 'Error de API: ${response.status}' 'API error: ${response.status}'
add_translation 'Netzwerkfehler' 'Error de red' 'Network error'
add_translation ' Suche...' ' Buscando...' ' Searching...'
add_translation 'Fehler: ${error}' 'Error: ${error}' 'Error: ${error}'

# Console logs (not part of the UI, but readable while debugging)
add_translation 'Kein TMDB-Link auf dieser Seite gefunden' 'No se encontró enlace de TMDB en esta página' 'No TMDB link found on this page'
add_translation 'Verarbeite TMDB ${mediaType}/${tmdbId}' 'Procesando TMDB ${mediaType}/${tmdbId}' 'Processing TMDB ${mediaType}/${tmdbId}'
add_translation 'Container eingefügt' 'Contenedor insertado' 'Container inserted'
add_translation 'Kein Einfügepunkt gefunden' 'No se encontró punto de inserción' 'No insertion point found'
add_translation 'Emby Elsewhere geladen!' 'Emby Elsewhere cargado!' 'Emby Elsewhere loaded!'

# Internal labels not shown in the UI (categoryConfig); translated anyway
# so the installed source reads consistently.
add_translation "label: 'Kostenlos'" "label: 'Gratis'" "label: 'Free'"
add_translation "label: 'Mit Werbung'" "label: 'Con publicidad'" "label: 'With ads'"
add_translation "label: 'Leihen'" "label: 'Alquilar'" "label: 'Rent'"
add_translation "label: 'Kaufen'" "label: 'Comprar'" "label: 'Buy'"

# Grammatical separator: "A, B und C" -> "A, B y C" / "A, B and C"
add_translation ' und ' ' y ' ' and '

# Human-readable name of a language code, for reports and messages.
elsewhere_language_name() {
    case "$1" in
        es) echo "Spanish" ;;
        en) echo "English" ;;
        de) echo "German (upstream, untouched)" ;;
        *)  echo "$1" ;;
    esac
}

# translate_elsewhere FILE REPORT LANG  -- LANG is es or en (de never gets here).
translate_elsewhere() {
    local file="$1" report="$2" lang="${3:-$ELSEWHERE_UI_LANGUAGE}"
    local i old new esc_old esc_new count total=0

    {
        echo "Emby Elsewhere - translation report: German -> $(elsewhere_language_name "$lang")"
        echo "=========================================================="
        echo
    } > "$report"

    for i in "${!ELSEWHERE_TR_DE[@]}"; do
        old="${ELSEWHERE_TR_DE[$i]}"
        case "$lang" in
            es) new="${ELSEWHERE_TR_ES[$i]}" ;;
            en) new="${ELSEWHERE_TR_EN[$i]}" ;;
            *)  die_critical "translate_elsewhere: unsupported language '$lang' (expected es or en)." ;;
        esac

        count="$({ grep -oF "$old" "$file" || true; } | wc -l | tr -d ' ')"
        if [ "$count" -gt 0 ]; then
            esc_old="$(sed_escape_pattern "$old")"
            esc_new="$(sed_escape_repl "$new")"
            sed -i "s/${esc_old}/${esc_new}/g" "$file"
            echo "${count}x  ${old}  ->  ${new}" >> "$report"
            total=$((total + count))
        fi
    done

    {
        echo
        echo "Total replacements: $total"
    } >> "$report"
}

# Non-fatal warning if known German words survived the translation -- this
# can happen when a newer addon version changed or added texts.
GERMAN_AUDIT_WORDS=(
    "Nicht verfügbar" "verfügbar" "Leihen" "Kaufen" "Einstellungen"
    "Anbieter" "Speichern" "Abbrechen" "Schließen" "Land hinzufügen"
    "Weitere Länder" "Standard-Suchland" "Streaming-Einstellungen"
    "Fehler" "Netzwerkfehler" " und " "eingefügt" "Einfügepunkt"
    "gefunden" "Verarbeite" "geladen"
)

audit_residual_german() {
    local file="$1"
    local w found=0

    for w in "${GERMAN_AUDIT_WORDS[@]}"; do
        if grep -qF "$w" "$file"; then
            warn "possible untranslated German text left in $(basename "$file"): '$w'"
            found=1
        fi
    done

    [ "$found" = "0" ] && ok "no known German text left in $(basename "$file")."
    return 0
}

# --- Copy the 6 addons to dashboard-ui (staging) --------------------------

for JS in "${JS_NAMES[@]}"; do
    cp "$SOURCE_DIR/$JS.original" "$DASHBOARD_UI/$JS"
    chmod 644 "$DASHBOARD_UI/$JS"
done
ok "6 addons copied to $DASHBOARD_UI (staging)."

if [ -n "$API_PROXY_URL" ]; then
    step "API proxy (smoke test against $API_PROXY_URL)"
    # End-to-end probe: TMDB /3/configuration requires a key; if the proxy
    # answers 200 with the placeholder, nginx dropped the placeholder, added
    # the real key and reached TMDB. Warning only: addons installed while
    # the proxy is down simply show no ratings until it is back, and the
    # rest of the install does not depend on this.
    API_SMOKE_TMP="$(mktemp "$CUSTOM_ROOT/.api-smoke.XXXXXX.tmp")"
    API_SMOKE_RESOLVE=()
    if [ -n "$API_PROXY_RESOLVE_IP" ]; then
        API_PROXY_HOST="${API_PROXY_URL#*://}"
        API_PROXY_HOST="${API_PROXY_HOST%%/*}"
        API_PROXY_PORT="${API_PROXY_HOST##*:}"
        [ "$API_PROXY_PORT" = "$API_PROXY_HOST" ] && API_PROXY_PORT="443"
        API_PROXY_HOST="${API_PROXY_HOST%%:*}"
        API_SMOKE_RESOLVE=(--resolve "$API_PROXY_HOST:$API_PROXY_PORT:$API_PROXY_RESOLVE_IP")
    fi
    API_SMOKE_STATUS="$(
        curl --silent --show-error --location \
            --connect-timeout 10 --max-time 20 \
            "${API_SMOKE_RESOLVE[@]}" \
            --header "Referer: $EMBY_URL/web/index.html" \
            --output "$API_SMOKE_TMP" --write-out '%{http_code}' \
            "${API_PROXY_URL}tmdb/3/configuration?api_key=$API_KEY_PLACEHOLDER" 2>/dev/null || true
    )"
    if [ "$API_SMOKE_STATUS" = "200" ] && grep -q '"images"' "$API_SMOKE_TMP"; then
        ok "The API proxy answers and TMDB accepts the key injected by nginx (HTTP 200${API_PROXY_RESOLVE_IP:+, via $API_PROXY_RESOLVE_IP})."
    else
        warn "The API proxy did not answer as expected (HTTP ${API_SMOKE_STATUS:-no response}). Response: $(http_body_snippet "$API_SMOKE_TMP")"
        warn "Installing anyway with the proxy URLs; TMDB/MDBList/Kinopoisk ratings will not show until the proxy works (check nginx: snippets/emby-api-proxy.conf, emby-api-keys.conf)."
    fi
    rm -f "$API_SMOKE_TMP"
fi

# --- 1) emby-elsewhere.js ------------------------------------------------

step "emby-elsewhere.js"
ELSEWHERE="$DASHBOARD_UI/emby-elsewhere.js"

# Which key ends up in each JS: in API-proxy mode, the placeholder (nginx
# adds the real one); otherwise the real key. The "is the key configured"
# conditionals keep looking at the real one: with no key configured there
# is nothing the proxy could add, so that provider stays off as today.
if [ -n "$API_PROXY_URL" ]; then
    JS_TMDB_API_KEY="$API_KEY_PLACEHOLDER"
    JS_MDBLIST_API_KEY="$API_KEY_PLACEHOLDER"
    JS_KINOPOISK_API_KEY="$API_KEY_PLACEHOLDER"
    API_KEYS_MODE_TEXT="placeholder (the real keys live in nginx: $API_PROXY_URL)"
else
    JS_TMDB_API_KEY="$TMDB_API_KEY"
    JS_MDBLIST_API_KEY="$MDBLIST_API_KEY"
    JS_KINOPOISK_API_KEY="$KINOPOISK_API_KEY"
    API_KEYS_MODE_TEXT="real (direct API calls from the browser)"
fi

set_or_die_const_string "$ELSEWHERE" "TMDB_API_KEY" "$JS_TMDB_API_KEY"
ok "TMDB_API_KEY injected: $API_KEYS_MODE_TEXT"
if [ -n "$API_PROXY_URL" ]; then
    N="$(rewrite_api_base "$ELSEWHERE" "$API_BASE_TMDB" "${API_PROXY_URL}tmdb/")"
    ok "TMDB via API proxy ($N URL(s) rewritten)."
    assert_no_third_party_keys "$ELSEWHERE"
fi

set_or_die_const_string "$ELSEWHERE" "DEFAULT_REGION" "$ELSEWHERE_DEFAULT_REGION"
ok "DEFAULT_REGION = $ELSEWHERE_DEFAULT_REGION"

# Upstream ships 'const CORS_PROXY_URL = '';' (deep links disabled). It is
# ALWAYS set to the configured value (empty included) so the installed file
# never depends on whatever upstream ships that day.
set_or_die_const_string "$ELSEWHERE" "CORS_PROXY_URL" "$ELSEWHERE_CORS_PROXY_URL"
if [ -n "$ELSEWHERE_CORS_PROXY_URL" ]; then
    ok "CORS_PROXY_URL = $ELSEWHERE_CORS_PROXY_URL ('where to watch' deep links enabled)"
else
    ok "CORS_PROXY_URL empty ('where to watch' deep links disabled)"
fi

ELSEWHERE_DEFAULT_PROVIDERS_JS="$(js_string_array_literal ELSEWHERE_DEFAULT_PROVIDERS)"
set_or_inject_const_array_raw "$ELSEWHERE" "DEFAULT_PROVIDERS" "$ELSEWHERE_DEFAULT_PROVIDERS_JS"
ok "DEFAULT_PROVIDERS = $ELSEWHERE_DEFAULT_PROVIDERS_JS"

ELSEWHERE_IGNORE_PROVIDERS_JS="$(js_string_array_literal ELSEWHERE_IGNORE_PROVIDERS)"
set_or_inject_const_array_raw "$ELSEWHERE" "IGNORE_PROVIDERS" "$ELSEWHERE_IGNORE_PROVIDERS_JS"
ok "IGNORE_PROVIDERS = $ELSEWHERE_IGNORE_PROVIDERS_JS"

if [ "$ELSEWHERE_UI_LANGUAGE" = "de" ]; then
    {
        echo "Emby Elsewhere - translation report"
        echo "==================================="
        echo
        echo "ELSEWHERE_UI_LANGUAGE=de: upstream German texts left untouched (0 replacements)."
    } > "$TRANSLATION_REPORT"
    ok "UI language: German (upstream texts left untouched, ELSEWHERE_UI_LANGUAGE=de)."
else
    translate_elsewhere "$ELSEWHERE" "$TRANSLATION_REPORT" "$ELSEWHERE_UI_LANGUAGE"
    ok "UI translated German -> $(elsewhere_language_name "$ELSEWHERE_UI_LANGUAGE") ($TRANSLATION_REPORT)."
    audit_residual_german "$ELSEWHERE"
fi

assert_no_emby_key "$ELSEWHERE"
ok "EMBY_API_KEY absent."

validate_js_syntax "$ELSEWHERE"

# --- 2) Spotlight.js ------------------------------------------------------
#
# Spotlight.js declares its configuration as properties of a CONFIG object
# (NAME: value,), not as 'const NAME = value;' -- that is why it uses the
# set_or_die_property_* helpers instead of the const ones.

step "Spotlight.js"
SPOTLIGHT="$DASHBOARD_UI/Spotlight.js"

set_or_die_property_string "$SPOTLIGHT" "TMDB_API_KEY" "$JS_TMDB_API_KEY"
ok "TMDB_API_KEY injected: $API_KEYS_MODE_TEXT"

if [ -n "$MDBLIST_API_KEY" ]; then
    set_or_die_property_string "$SPOTLIGHT" "MDBLIST_API_KEY" "$JS_MDBLIST_API_KEY"
    ok "MDBLIST_API_KEY injected."
else
    warn "MDBLIST_API_KEY not configured: not injected into Spotlight.js."
fi

if [ -n "$KINOPOISK_API_KEY" ]; then
    set_or_die_property_string "$SPOTLIGHT" "KINOPOISK_API_KEY" "$JS_KINOPOISK_API_KEY"
    ok "KINOPOISK_API_KEY injected."
else
    warn "KINOPOISK_API_KEY not configured: not injected into Spotlight.js."
fi

if [ -n "$API_PROXY_URL" ]; then
    N1="$(rewrite_api_base "$SPOTLIGHT" "$API_BASE_MDBLIST" "${API_PROXY_URL}mdblist/")"
    N2="$(rewrite_api_base "$SPOTLIGHT" "$API_BASE_KINOPOISK" "${API_PROXY_URL}kinopoisk/")"
    ok "MDBList and Kinopoisk via API proxy ($N1 + $N2 URLs rewritten)."
    assert_no_third_party_keys "$SPOTLIGHT"
fi

step "Spotlight.js - additional configuration"

set_or_die_property_raw    "$SPOTLIGHT" "limit"                 "$SPOTLIGHT_LIMIT"
set_or_die_property_raw    "$SPOTLIGHT" "autoplayInterval"      "$SPOTLIGHT_AUTOPLAY_INTERVAL"
set_or_die_property_string "$SPOTLIGHT" "vignetteColorTop"      "$SPOTLIGHT_VIGNETTE_TOP"
set_or_die_property_string "$SPOTLIGHT" "vignetteColorBottom"   "$SPOTLIGHT_VIGNETTE_BOTTOM"
set_or_die_property_string "$SPOTLIGHT" "vignetteColorLeft"     "$SPOTLIGHT_VIGNETTE_LEFT"
set_or_die_property_string "$SPOTLIGHT" "vignetteColorRight"    "$SPOTLIGHT_VIGNETTE_RIGHT"
set_or_die_property_string "$SPOTLIGHT" "playbuttonColor"       "$SPOTLIGHT_PLAYBUTTON_COLOR"
set_or_die_property_string "$SPOTLIGHT" "customItemsFile"       "$SPOTLIGHT_CUSTOM_ITEMS_FILE"
set_or_die_property_raw    "$SPOTLIGHT" "enableVideoBackdrop"   "$SPOTLIGHT_ENABLE_VIDEO_BACKDROP"
set_or_die_property_raw    "$SPOTLIGHT" "startMuted"            "$SPOTLIGHT_START_MUTED"
set_or_die_property_raw    "$SPOTLIGHT" "videoVolume"           "$SPOTLIGHT_VIDEO_VOLUME"
set_or_die_property_raw    "$SPOTLIGHT" "waitForTrailerToEnd"   "$SPOTLIGHT_WAIT_FOR_TRAILER_TO_END"
set_or_die_property_raw    "$SPOTLIGHT" "enableMobileVideo"     "$SPOTLIGHT_ENABLE_MOBILE_VIDEO"
set_or_die_property_string "$SPOTLIGHT" "preferredVideoQuality" "$SPOTLIGHT_PREFERRED_VIDEO_QUALITY"
set_or_die_property_raw    "$SPOTLIGHT" "enableSponsorBlock"    "$SPOTLIGHT_ENABLE_SPONSOR_BLOCK"
set_or_die_property_raw    "$SPOTLIGHT" "CACHE_TTL_HOURS"       "$SPOTLIGHT_CACHE_TTL_HOURS"
set_or_die_property_string "$SPOTLIGHT" "CORS_PROXY_URL"        "$SPOTLIGHT_CORS_PROXY_URL"
set_or_die_property_raw    "$SPOTLIGHT" "enableCustomRatings"   "$SPOTLIGHT_ENABLE_CUSTOM_RATINGS"
set_or_die_property_raw    "$SPOTLIGHT" "enableIMDb"            "$SPOTLIGHT_ENABLE_IMDB"
set_or_die_property_raw    "$SPOTLIGHT" "enableTMDb"            "$SPOTLIGHT_ENABLE_TMDB"
set_or_die_property_raw    "$SPOTLIGHT" "enableRottenTomatoes"  "$SPOTLIGHT_ENABLE_ROTTEN_TOMATOES"
set_or_die_property_raw    "$SPOTLIGHT" "enableMetacritic"      "$SPOTLIGHT_ENABLE_METACRITIC"
set_or_die_property_raw    "$SPOTLIGHT" "enableTrakt"           "$SPOTLIGHT_ENABLE_TRAKT"
set_or_die_property_raw    "$SPOTLIGHT" "enableLetterboxd"      "$SPOTLIGHT_ENABLE_LETTERBOXD"
set_or_die_property_raw    "$SPOTLIGHT" "enableRogerEbert"      "$SPOTLIGHT_ENABLE_ROGER_EBERT"
set_or_die_property_raw    "$SPOTLIGHT" "enableAllocine"        "$SPOTLIGHT_ENABLE_ALLOCINE"
set_or_die_property_raw    "$SPOTLIGHT" "enableKinopoisk"       "$SPOTLIGHT_ENABLE_KINOPOISK"
set_or_die_property_raw    "$SPOTLIGHT" "enableMyAnimeList"     "$SPOTLIGHT_ENABLE_MY_ANIME_LIST"
set_or_die_property_raw    "$SPOTLIGHT" "enableAniList"         "$SPOTLIGHT_ENABLE_ANI_LIST"

ok "Additional Spotlight configuration applied (29 properties)."

assert_no_emby_key "$SPOTLIGHT"
ok "EMBY_API_KEY absent."

validate_js_syntax "$SPOTLIGHT"

# --- 3) Reviews.js ---------------------------------------------------------

step "Reviews.js"
REVIEWS="$DASHBOARD_UI/Reviews.js"
reset_inject_anchor

# TMDB_API_KEY is only injected if the declaration ALREADY exists in the original.
if set_if_declared_const_string "$REVIEWS" "TMDB_API_KEY" "$JS_TMDB_API_KEY"; then
    ok "TMDB_API_KEY already existed in Reviews.js: injected ($API_KEYS_MODE_TEXT)."
else
    warn "TMDB_API_KEY does not exist in the original Reviews.js: NOT added (explicit security rule)."
fi
if [ -n "$API_PROXY_URL" ]; then
    N="$(rewrite_api_base "$REVIEWS" "$API_BASE_TMDB" "${API_PROXY_URL}tmdb/")"
    ok "TMDB via API proxy ($N URL(s) rewritten)."
    assert_no_third_party_keys "$REVIEWS"
fi

set_or_inject_const_string "$REVIEWS" "PRIMARY_LANGUAGE" "$REVIEWS_PRIMARY_LANGUAGE"
ok "PRIMARY_LANGUAGE = $REVIEWS_PRIMARY_LANGUAGE"

set_or_inject_const_string "$REVIEWS" "SECONDARY_LANGUAGE" "$REVIEWS_SECONDARY_LANGUAGE"
ok "SECONDARY_LANGUAGE = $REVIEWS_SECONDARY_LANGUAGE"

set_or_inject_const_raw "$REVIEWS" "MAX_REVIEWS" "$REVIEWS_MAX_REVIEWS"
ok "MAX_REVIEWS = $REVIEWS_MAX_REVIEWS (numeric)"

verify_or_warn_const_raw "$REVIEWS" "REVIEW_PREVIEW_LENGTH" "$REVIEWS_PREVIEW_LENGTH"
verify_or_warn_const_raw "$REVIEWS" "EXPANDED_BY_DEFAULT" "$REVIEWS_EXPANDED_BY_DEFAULT"
verify_or_warn_const_raw "$REVIEWS" "SHOW_LANGUAGE_FLAGS" "$REVIEWS_SHOW_LANGUAGE_FLAGS"

assert_no_emby_key "$REVIEWS"
ok "EMBY_API_KEY absent."

validate_js_syntax "$REVIEWS"

# --- 4) emby-ratings.js ----------------------------------------------------
#
# Like Spotlight.js, it declares its configuration as properties of its own
# CONFIG object (it shares no runtime state with Spotlight, but uses the
# same 3 account API keys). Without this injection the addon ends up
# installed but shows no rating at all.

step "emby-ratings.js"
RATINGS="$DASHBOARD_UI/emby-ratings.js"

set_or_die_property_string "$RATINGS" "TMDB_API_KEY" "$JS_TMDB_API_KEY"
ok "TMDB_API_KEY injected: $API_KEYS_MODE_TEXT"

if [ -n "$MDBLIST_API_KEY" ]; then
    set_or_die_property_string "$RATINGS" "MDBLIST_API_KEY" "$JS_MDBLIST_API_KEY"
    ok "MDBLIST_API_KEY injected."
else
    warn "MDBLIST_API_KEY not configured: not injected into emby-ratings.js."
fi

if [ -n "$KINOPOISK_API_KEY" ]; then
    set_or_die_property_string "$RATINGS" "KINOPOISK_API_KEY" "$JS_KINOPOISK_API_KEY"
    ok "KINOPOISK_API_KEY injected."
else
    warn "KINOPOISK_API_KEY not configured: not injected into emby-ratings.js."
fi

if [ -n "$API_PROXY_URL" ]; then
    N1="$(rewrite_api_base "$RATINGS" "$API_BASE_TMDB" "${API_PROXY_URL}tmdb/")"
    N2="$(rewrite_api_base "$RATINGS" "$API_BASE_MDBLIST" "${API_PROXY_URL}mdblist/")"
    N3="$(rewrite_api_base "$RATINGS" "$API_BASE_KINOPOISK" "${API_PROXY_URL}kinopoisk/")"
    ok "TMDB, MDBList and Kinopoisk via API proxy ($N1 + $N2 + $N3 URLs rewritten)."
    assert_no_third_party_keys "$RATINGS"
fi

set_or_die_property_raw    "$RATINGS" "enableIMDb"           "$RATINGS_ENABLE_IMDB"
set_or_die_property_raw    "$RATINGS" "enableTMDb"           "$RATINGS_ENABLE_TMDB"
set_or_die_property_raw    "$RATINGS" "enableRottenTomatoes" "$RATINGS_ENABLE_ROTTEN_TOMATOES"
set_or_die_property_raw    "$RATINGS" "enableMetacritic"     "$RATINGS_ENABLE_METACRITIC"
set_or_die_property_raw    "$RATINGS" "enableTrakt"          "$RATINGS_ENABLE_TRAKT"
set_or_die_property_raw    "$RATINGS" "enableLetterboxd"     "$RATINGS_ENABLE_LETTERBOXD"
set_or_die_property_raw    "$RATINGS" "enableRogerEbert"     "$RATINGS_ENABLE_ROGER_EBERT"
set_or_die_property_raw    "$RATINGS" "enableAllocine"       "$RATINGS_ENABLE_ALLOCINE"
set_or_die_property_raw    "$RATINGS" "enableKinopoisk"      "$RATINGS_ENABLE_KINOPOISK"
set_or_die_property_raw    "$RATINGS" "enableMyAnimeList"    "$RATINGS_ENABLE_MY_ANIME_LIST"
set_or_die_property_raw    "$RATINGS" "enableAniList"        "$RATINGS_ENABLE_ANI_LIST"
set_or_die_property_raw    "$RATINGS" "CACHE_TTL_HOURS"      "$RATINGS_CACHE_TTL_HOURS"
set_or_die_property_string "$RATINGS" "CORS_PROXY_URL"       "$RATINGS_CORS_PROXY_URL"

ok "emby-ratings.js configuration applied."

assert_no_emby_key "$RATINGS"
ok "EMBY_API_KEY absent."

validate_js_syntax "$RATINGS"

# --- 5-6) addons without edits (installed exactly as downloaded) ---------

for JS in "${JS_NAMES[@]}"; do
    case " ${EDITED_JS[*]} " in
        *" $JS "*) continue ;;
    esac
    assert_no_emby_key "$DASHBOARD_UI/$JS"
    validate_js_syntax "$DASHBOARD_UI/$JS"
    ok "$JS unchanged (requires no API keys or configurable values)."
done

# --- Final size validation of every editable/installable JS ---------------

for JS in "${JS_NAMES[@]}"; do
    SIZE="$(wc -c < "$DASHBOARD_UI/$JS" | tr -d ' ')"
    [ "$SIZE" -gt 100 ] || die_precheck "$JS became suspiciously small after editing ($SIZE bytes)."
done
ok "All addons exceed 100 bytes after editing."

# ==============================================================================
# 12. <script> INJECTION INTO index.html (staging)
# ==============================================================================

section "PHASE 6/9 - index.html preparation"

step "Fetching the current index.html from the container (to build the base)"

docker cp "$CONTAINER:$INDEX_CONTAINER_PATH" "$CUSTOM_ROOT/index.html.current"

# The baseline (index.html.original) is compared against the container's
# current index.html WITH our <script> tags already removed, instead of
# just checking whether it has our tags or not. That way, if Emby updated
# its own index.html between one installation and the next, it is detected
# and the baseline is refreshed instead of re-injecting over a stale copy
# forever.
CURRENT_STRIPPED="$CUSTOM_ROOT/.index.html.current-stripped.tmp"
cp "$CUSTOM_ROOT/index.html.current" "$CURRENT_STRIPPED"
for JS in "${JS_NAMES[@]}"; do
    ESC_JS="$(printf '%s' "$JS" | sed 's/[.[\*^$/]/\\&/g')"
    # Anchor to the real shape of the <script ... src="NAME.js" ...> tag
    # instead of deleting any line that merely CONTAINS the addon name as
    # a substring -- if Emby's own index.html ever mentions that name in
    # another context (comment, inline config), that line must not
    # disappear.
    sed -i -E "/<script[^>]*src=\"${ESC_JS}\"[^>]*>/d" "$CURRENT_STRIPPED"
done

if [ -s "$ORIGINAL_INDEX" ]; then
    if cmp -s "$CURRENT_STRIPPED" "$ORIGINAL_INDEX"; then
        ok "index.html.original is still current (no upstream changes detected)."
    else
        warn "The container's index.html changed since the last installation (outside our <script> tags) -- updating the saved baseline."
        cp "$CURRENT_STRIPPED" "$ORIGINAL_INDEX"
        chmod 644 "$ORIGINAL_INDEX"
    fi
else
    cp "$CURRENT_STRIPPED" "$ORIGINAL_INDEX"
    chmod 644 "$ORIGINAL_INDEX"
    ok "index.html.original created from the current state."
fi

cp "$ORIGINAL_INDEX" "$DASHBOARD_UI/index.html"
rm -f "$CURRENT_STRIPPED"

STAGED_INDEX="$DASHBOARD_UI/index.html"

step "Injecting <script> tags (idempotent)"

grep -q '</body>' "$STAGED_INDEX" \
    || die_precheck "index.html does not contain </body>; cannot inject safely."

# 1) remove previous references to any of our addons (same anchoring to the
#    real tag as above, not a substring of the file name)
for JS in "${JS_NAMES[@]}"; do
    ESC_JS="$(printf '%s' "$JS" | sed 's/[.[\*^$/]/\\&/g')"
    sed -i -E "/<script[^>]*src=\"${ESC_JS}\"[^>]*>/d" "$STAGED_INDEX"
done

# 2) inject one <script> line per addon, right before </body>
INJECTION="$(
    for JS in "${JS_NAMES[@]}"; do
        printf '    <script src="%s" defer></script>\n' "$JS"
    done
)"

awk -v inj="$INJECTION" '
    /<\/body>/ && !done { print inj; done=1 }
    { print }
' "$STAGED_INDEX" > "$STAGED_INDEX.new"
mv "$STAGED_INDEX.new" "$STAGED_INDEX"

for JS in "${JS_NAMES[@]}"; do
    COUNT="$(grep -cF "$JS" "$STAGED_INDEX" || true)"
    [ "$COUNT" = "1" ] || die_precheck "$JS appears $COUNT times in index.html after injection (expected: 1)."
done
ok "6 addons referenced exactly once in index.html."

assert_no_emby_key "$STAGED_INDEX"
ok "EMBY_API_KEY absent from index.html."

chmod 644 "$STAGED_INDEX"
rm -f "$CUSTOM_ROOT/index.html.current"

# ==============================================================================
# 12b. THEME PREPARATION (modules/skinmanager.js + theme.css)
# ==============================================================================

section "PHASE 6/9 - Theme preparation: $THEME_NAME"

# THEME_MODE decides how Embymalism reaches Emby:
#   theme     -> entry in the "Theme" dropdown (patched skinmanager.js) and
#                Branding CustomCss EMPTY. This is the normal mode.
#   customcss -> previous behaviour (CSS embedded in Branding), only as a
#                fallback if the container's skinmanager.js lacks the
#                expected anchor (Emby changed it) or could not be read.
THEME_MODE="theme"
THEME_FALLBACK_REASON=""
ORIGINAL_SKINMANAGER="$CUSTOM_ROOT/skinmanager.js.original"
STAGED_SKINMANAGER="$DASHBOARD_UI/$SKINMANAGER_REL"
STAGED_THEME_CSS="$DASHBOARD_UI/$THEME_CSS_REL"

step "Fetching the current $SKINMANAGER_REL from the container (to build the base)"

SKINMANAGER_CURRENT="$CUSTOM_ROOT/skinmanager.js.current"
rm -f "$SKINMANAGER_CURRENT"
if docker cp "$CONTAINER:$SKINMANAGER_CONTAINER_PATH" "$SKINMANAGER_CURRENT" 2>/dev/null && [ -s "$SKINMANAGER_CURRENT" ]; then
    # Same criterion as index.html: the baseline is the container's file
    # WITH our entry removed, compared against the saved baseline, to detect
    # that Emby changed its own file between installations.
    SKINMANAGER_STRIPPED="$CUSTOM_ROOT/.skinmanager.js.current-stripped.tmp"
    cp "$SKINMANAGER_CURRENT" "$SKINMANAGER_STRIPPED"
    theme_strip_entry "$SKINMANAGER_STRIPPED"

    if [ -s "$ORIGINAL_SKINMANAGER" ]; then
        if cmp -s "$SKINMANAGER_STRIPPED" "$ORIGINAL_SKINMANAGER"; then
            ok "skinmanager.js.original is still current (no upstream changes detected)."
        else
            warn "The container's $SKINMANAGER_REL changed since the last installation (outside our entry) -- updating the saved baseline."
            cp "$SKINMANAGER_STRIPPED" "$ORIGINAL_SKINMANAGER"
            chmod 644 "$ORIGINAL_SKINMANAGER"
        fi
    else
        cp "$SKINMANAGER_STRIPPED" "$ORIGINAL_SKINMANAGER"
        chmod 644 "$ORIGINAL_SKINMANAGER"
        ok "skinmanager.js.original created from the current state."
    fi
    rm -f "$SKINMANAGER_STRIPPED"
else
    THEME_MODE="customcss"
    THEME_FALLBACK_REASON="could not read $SKINMANAGER_CONTAINER_PATH from the container"
fi
rm -f "$SKINMANAGER_CURRENT"

if [ "$THEME_MODE" = "theme" ]; then
    step "Injecting the '$THEME_NAME' entry into $SKINMANAGER_REL (idempotent)"
    mkdir -p "$(dirname "$STAGED_SKINMANAGER")" "$(dirname "$STAGED_THEME_CSS")"
    cp "$ORIGINAL_SKINMANAGER" "$STAGED_SKINMANAGER"
    if theme_inject_entry "$STAGED_SKINMANAGER"; then
        theme_verify_patched "$STAGED_SKINMANAGER" \
            || die_precheck "$SKINMANAGER_REL became inconsistent after injecting the theme entry (structural verification failed). The container was not touched."
        validate_js_syntax "$STAGED_SKINMANAGER"
        assert_no_emby_key "$STAGED_SKINMANAGER"
        chmod 644 "$STAGED_SKINMANAGER"
        if [ "$THEME_SET_AS_DEFAULT" = "1" ]; then
            ok "Entry '$THEME_NAME' inserted before the Light entry and set as the default theme ($(wc -c < "$ORIGINAL_SKINMANAGER" | tr -d ' ') -> $(wc -c < "$STAGED_SKINMANAGER" | tr -d ' ') bytes); the Dark entry remains intact and selectable."
        else
            ok "Entry '$THEME_NAME' inserted before the Light entry ($(wc -c < "$ORIGINAL_SKINMANAGER" | tr -d ' ') -> $(wc -c < "$STAGED_SKINMANAGER" | tr -d ' ') bytes); Dark remains the default theme (--no-default-theme)."
        fi

        cp "$CSS_SOURCE" "$STAGED_THEME_CSS"
        chmod 644 "$STAGED_THEME_CSS"
        ok "$THEME_CSS_REL prepared (full contents of $CSS_NAME, sha256 $CSS_HASH)."
    else
        THEME_MODE="customcss"
        THEME_FALLBACK_REASON="$SKINMANAGER_REL does not contain the expected anchor ($(theme_count_literal "$STAGED_SKINMANAGER" "$THEME_ANCHOR") occurrences of the Light entry; expected 1) -- Emby probably changed the file"
        rm -f "$STAGED_SKINMANAGER" "$STAGED_THEME_CSS"
    fi
fi

if [ "$THEME_MODE" = "customcss" ]; then
    rm -f "$STAGED_SKINMANAGER" "$STAGED_THEME_CSS"
    warn "Cannot register '$THEME_NAME' as a theme: $THEME_FALLBACK_REASON."
    warn "Falling back to the previous mode: $CSS_NAME embedded in the Branding CustomCss (global, also affects the admin dashboard)."
    warn "Check $SKINMANAGER_REL in this Emby version ($EMBY_SERVER_VERSION) and update THEME_ANCHOR/THEME_ENTRY in this script."
fi

# ==============================================================================
# 13. BACKUP OF THE CURRENT CONTAINER STATE
# ==============================================================================

# --dry-run stops here: everything above only read from the container and
# wrote to the staging area under $CUSTOM_ROOT; everything below changes
# the container or Emby's Branding configuration.
if [ "$DRY_RUN" = "1" ]; then
    section "DRY RUN - stopping before backup/install"
    echo "Nothing was changed in the container or in Emby. What WOULD be installed:"
    echo "  Container:      $CONTAINER ($CONTAINER_IMAGE)"
    echo "  Staged addons:  $DASHBOARD_UI/ (${#JS_NAMES[@]} files, keys: $API_KEYS_MODE_TEXT)"
    echo "  index.html:     $STAGED_INDEX"
    if [ "$THEME_MODE" = "theme" ]; then
        echo "  Theme:          '$THEME_NAME' via $STAGED_SKINMANAGER + $STAGED_THEME_CSS (default for all users: $THEME_SET_AS_DEFAULT)"
        echo "  Branding CSS:   would be emptied"
    else
        echo "  Theme:          NOT registered (fallback to CustomCss: $THEME_FALLBACK_REASON)"
        echo "  Branding CSS:   would be replaced with $CSS_NAME ($CSS_HASH)"
    fi
    echo "  CORS proxy:     ${CORS_PROXY_URL:-(empty)}"
    echo "  API proxy:      ${API_PROXY_URL:-(empty)}"
    echo "  Config file:    ${CONFIG_FILE_USED:-(none)}"
    echo
    echo "Re-run without --dry-run to install."
    rm -f "$KNOWN_HASHES_NEW"
    exit "$EXIT_OK"
fi

section "PHASE 7/9 - Backup"

step "Verifying container identity before touching anything"

# CONTAINER is referenced by NAME throughout the rest of the script, but
# Docker resolves that name to whichever container exists at that moment --
# if someone (TrueNAS, a manual 'docker compose up', an app update) recreated
# the container with the same name since PHASE 2/9, a backup taken now would
# describe a different instance than the one detected/validated at the
# start. The real Id is compared against the one captured during detection;
# if it differs, abort BEFORE taking the backup (nothing has been touched
# yet) instead of continuing with a backup that would no longer match the
# container that is going to be installed later on.
CURRENT_CONTAINER_ID="$(docker inspect "$CONTAINER" -f '{{.Id}}' 2>/dev/null || true)"
[ -n "$CURRENT_CONTAINER_ID" ] && [ "$CURRENT_CONTAINER_ID" = "$CONTAINER_ID" ] \
    || die_precheck "Container '$CONTAINER' changed identity since the initial detection (was it recreated?). Nothing was touched; re-run the script from scratch."
ok "Container '$CONTAINER' is still the same instance that was detected (${CONTAINER_ID:0:12})."

step "index.html"
docker cp "$CONTAINER:$INDEX_CONTAINER_PATH" "$BACKUP_DIR/index.html"
[ -s "$BACKUP_DIR/index.html" ] \
    || die_precheck "The index.html backup is empty after docker cp; it cannot be trusted for a rollback. Nothing was touched."
ok "index.html backup saved."

step "Theme $THEME_NAME (current skinmanager.js + theme.css)"
# skinmanager.js is backed up whenever it exists (even if this run falls
# back to CustomCss mode): it is an Emby core file and the rollback restores
# it exactly as it was. theme.css only exists if a previous installation
# left it; otherwise it is documented so the rollback removes it.
if docker exec "$CONTAINER" sh -c "test -f '$SKINMANAGER_CONTAINER_PATH'"; then
    docker cp "$CONTAINER:$SKINMANAGER_CONTAINER_PATH" "$BACKUP_DIR/skinmanager.js"
    [ -s "$BACKUP_DIR/skinmanager.js" ] \
        || die_precheck "The skinmanager.js backup is empty after docker cp; it cannot be trusted for a rollback. Nothing was touched yet."
    ok "skinmanager.js backed up."
else
    log "  -- $SKINMANAGER_REL does not exist in the container (documented; the rollback will not touch it)."
fi
if docker exec "$CONTAINER" sh -c "test -f '$THEME_CSS_CONTAINER_PATH'"; then
    docker cp "$CONTAINER:$THEME_CSS_CONTAINER_PATH" "$BACKUP_DIR/theme.css"
    [ -s "$BACKUP_DIR/theme.css" ] \
        || die_precheck "The theme.css backup is empty after docker cp; it cannot be trusted for a rollback. Nothing was touched yet."
    ok "theme.css ($THEME_ID) backed up."
else
    log "  -- $THEME_CSS_REL did not exist before (documented so it can be removed in a rollback)."
fi

step "Existing addons"

# Baseline of the last SUCCESSFUL installation (if any), to detect whether
# someone edited an addon by hand since then -- the same as is already done
# for index.html below (PHASE 6/9), but for the 6 JS files.
LAST_INSTALLED_HASHES_DIR="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "$TIMESTAMP" 2>/dev/null | sort | tail -n1 || true)"
LAST_INSTALLED_HASHES_FILE=""
if [ -n "$LAST_INSTALLED_HASHES_DIR" ] && [ -f "$LAST_INSTALLED_HASHES_DIR/installed-SHA256SUMS.txt" ]; then
    LAST_INSTALLED_HASHES_FILE="$LAST_INSTALLED_HASHES_DIR/installed-SHA256SUMS.txt"
fi

for JS in "${JS_NAMES[@]}"; do
    if docker exec "$CONTAINER" sh -c "test -f '$DASHBOARD_CONTAINER_DIR/$JS'"; then
        docker cp "$CONTAINER:$DASHBOARD_CONTAINER_DIR/$JS" "$BACKUP_DIR/$JS"
        [ -s "$BACKUP_DIR/$JS" ] \
            || die_precheck "The $JS backup is empty after docker cp; it cannot be trusted for a rollback. Nothing was touched yet."

        if [ -n "$LAST_INSTALLED_HASHES_FILE" ]; then
            PREV_JS_HASH="$(awk -v n="$JS" '$2 == n {print $1; exit}' "$LAST_INSTALLED_HASHES_FILE" 2>/dev/null || true)"
            CURRENT_JS_HASH="$(sha256sum "$BACKUP_DIR/$JS" | awk '{print $1}')"
            if [ -n "$PREV_JS_HASH" ] && [ "$PREV_JS_HASH" != "$CURRENT_JS_HASH" ]; then
                warn "$JS in the container differs from what was installed last time (edited by hand, or container recreated with another version?) -- overwriting it anyway, as this installer is meant to."
            fi
        fi

        ok "$JS backed up."
    else
        log "  -- $JS did not exist before (documented so it can be removed in a rollback)."
    fi
done

step "Current CustomCss (Branding/Configuration)"

BRANDING_BEFORE_TMP="$(mktemp "$CUSTOM_ROOT/.branding-before.XXXXXX.tmp")"
BRANDING_BEFORE_STATUS="$(
    curl --silent --show-error --location \
        --connect-timeout 10 --max-time 30 \
        -K "$EMBY_TOKEN_CURL_CONFIG" \
        --header "Accept: application/json" \
        --output "$BRANDING_BEFORE_TMP" --write-out '%{http_code}' \
        "$EMBY_URL$EMBY_BRANDING_GET_PATH" 2>/dev/null || true
)"

if [ "$BRANDING_BEFORE_STATUS" != "200" ]; then
    BRANDING_BEFORE_SNIPPET="$(http_body_snippet "$BRANDING_BEFORE_TMP")"
    rm -f "$BRANDING_BEFORE_TMP"
    die_precheck "Could not back up Branding/Configuration before installing (HTTP ${BRANDING_BEFORE_STATUS:-no response}). Response: ${BRANDING_BEFORE_SNIPPET:-(empty)}"
fi

grep -q '"CustomCss"' "$BRANDING_BEFORE_TMP" \
    || die_precheck "The Branding/Configuration backup does not contain CustomCss; aborting for safety."

mv "$BRANDING_BEFORE_TMP" "$BACKUP_DIR/branding-before.json"

CSS_BEFORE_SIZE="$(wc -c < "$BACKUP_DIR/branding-before.json" | tr -d ' ')"
ok "branding-before.json saved ($CSS_BEFORE_SIZE bytes)."

step "Packaging portable backup ($BACKUP_TGZ)"

tar -czf "$BACKUP_TGZ" -C "$BACKUP_ROOT" "$TIMESTAMP" \
    || die_precheck "Could not create the portable backup $BACKUP_TGZ. The container was not touched."

[ -s "$BACKUP_TGZ" ] \
    || die_precheck "$BACKUP_TGZ is empty after packaging. The container was not touched."

ok "$BACKUP_TGZ ($(wc -c < "$BACKUP_TGZ" | tr -d ' ') bytes)."

# ==============================================================================
# 14. GENERATE ROLLBACK AND REAPPLY (before installing, so it is possible to
#     revert even if the installation fails halfway through)
# ==============================================================================

step "Generating rollback-$TIMESTAMP.sh and reapply-$TIMESTAMP.sh"

JS_NAMES_BASH_ARRAY="$(printf '    "%s"\n' "${JS_NAMES[@]}")"

cat > "$ROLLBACK_FILE" <<ROLLBACK_EOF
#!/usr/bin/env bash
# Rollback generated by install-emby-custom.sh on $TIMESTAMP.
# Reads the credentials from api.env at run time; never embeds them.
set -Eeuo pipefail

CONTAINER=$(shell_single_quote "$CONTAINER")
EMBY_URL=$(shell_single_quote "$EMBY_URL")
INDEX=$(shell_single_quote "$INDEX_CONTAINER_PATH")
DASHBOARD_DIR=$(shell_single_quote "$DASHBOARD_CONTAINER_DIR")
SKINMANAGER=$(shell_single_quote "$SKINMANAGER_CONTAINER_PATH")
THEME_CSS=$(shell_single_quote "$THEME_CSS_CONTAINER_PATH")
BACKUP_DIR=$(shell_single_quote "$BACKUP_DIR")
BACKUP_TGZ=$(shell_single_quote "$BACKUP_TGZ")
SECRETS_FILE=$(shell_single_quote "$SECRETS_FILE")
EMBY_BRANDING_POST_PATH=$(shell_single_quote "$EMBY_BRANDING_POST_PATH")

JS_NAMES=(
$JS_NAMES_BASH_ARRAY
)

$SHARED_RESTORE_FUNCTIONS

echo
echo "=================================================================="
echo " MANUAL ROLLBACK - $TIMESTAMP"
echo "=================================================================="
echo

# If the original backup directory is gone (custom/backups/ was moved or
# lost, or this script was copied to another machine together with the
# .tgz) but the portable backup is present, it is extracted to a temporary
# directory and everything continues exactly the same -- the rest of this
# script does not care where \$BACKUP_DIR came from.
if [ ! -d "\$BACKUP_DIR" ]; then
    if [ -f "\$BACKUP_TGZ" ]; then
        echo "NOTICE: \$BACKUP_DIR does not exist; extracting from the portable backup \$BACKUP_TGZ..."
        EXTRACTED_BACKUP_ROOT="\$(mktemp -d)"
        if tar -xzf "\$BACKUP_TGZ" -C "\$EXTRACTED_BACKUP_ROOT"; then
            BACKUP_DIR="\$EXTRACTED_BACKUP_ROOT/\$(basename "\$BACKUP_DIR")"
            [ -d "\$BACKUP_DIR" ] || {
                echo "ERROR: \$BACKUP_TGZ does not contain the expected directory after extraction."
                exit 1
            }
            echo "  OK extracted to \$BACKUP_DIR"
        else
            echo "ERROR: could not extract \$BACKUP_TGZ."
            exit 1
        fi
    else
        echo "ERROR: neither \$BACKUP_DIR nor the portable backup \$BACKUP_TGZ exists. Nothing to restore from."
        exit 1
    fi
fi

docker inspect "\$CONTAINER" >/dev/null 2>&1 || {
    echo "ERROR: container \$CONTAINER does not exist."
    exit 1
}

HAD_FAILURE=0
HAD_SUCCESS=0

echo "Restoring index.html..."
if restore_or_warn_file "\$CONTAINER" "\$BACKUP_DIR/index.html" "\$INDEX" "index.html"; then
    HAD_SUCCESS=1
else
    RC=\$?
    [ "\$RC" = "1" ] && HAD_FAILURE=1
fi

for JS in "\${JS_NAMES[@]}"; do
    if restore_or_remove_file "\$CONTAINER" "\$BACKUP_DIR/\$JS" "\$DASHBOARD_DIR/\$JS" "\$JS"; then
        HAD_SUCCESS=1
    else
        RC=\$?
        [ "\$RC" = "1" ] && HAD_FAILURE=1
    fi
done

echo "Restoring theme (skinmanager.js + theme.css)..."
if restore_or_warn_file "\$CONTAINER" "\$BACKUP_DIR/skinmanager.js" "\$SKINMANAGER" "skinmanager.js"; then
    HAD_SUCCESS=1
else
    RC=\$?
    [ "\$RC" = "1" ] && HAD_FAILURE=1
fi
if restore_or_remove_file "\$CONTAINER" "\$BACKUP_DIR/theme.css" "\$THEME_CSS" "theme.css"; then
    HAD_SUCCESS=1
else
    RC=\$?
    [ "\$RC" = "1" ] && HAD_FAILURE=1
fi

# chmod only what still exists (the addons just removed must not produce
# a "No such file or directory").
for P in "\$INDEX" "\$SKINMANAGER" "\$THEME_CSS"; do
    docker exec "\$CONTAINER" sh -c "[ ! -f '\$P' ] || chmod 644 '\$P'" || true
done
for JS in "\${JS_NAMES[@]}"; do
    docker exec "\$CONTAINER" sh -c "[ ! -f '\$DASHBOARD_DIR/\$JS' ] || chmod 644 '\$DASHBOARD_DIR/\$JS'" || true
done

if [ -f "\$BACKUP_DIR/branding-before.json" ]; then
    if [ ! -f "\$SECRETS_FILE" ]; then
        echo "  WARNING: \$SECRETS_FILE not found; CustomCss cannot be restored via API."
    else
        # shellcheck disable=SC1090
        source "\$SECRETS_FILE"
        TOKEN_CONFIG="\$(mktemp)"
        chmod 600 "\$TOKEN_CONFIG"
        printf 'header = "X-Emby-Token: %s"\n' "\$(curl_config_escape "\${EMBY_API_KEY:-}")" > "\$TOKEN_CONFIG"
        echo "Restoring Custom CSS..."
        if restore_css_from_backup "\$BACKUP_DIR/branding-before.json" "\$EMBY_URL" "\$EMBY_BRANDING_POST_PATH" "\$TOKEN_CONFIG"; then
            HAD_SUCCESS=1
        else
            HAD_FAILURE=1
        fi
        rm -f "\$TOKEN_CONFIG"
    fi
fi

if [ "\$HAD_FAILURE" = "1" ]; then
    if [ "\$HAD_SUCCESS" = "1" ]; then
        ROLLBACK_RESULT="PARTIAL"
    else
        ROLLBACK_RESULT="FAILED"
    fi
else
    ROLLBACK_RESULT="SUCCESS"
fi

echo
echo "ROLLBACK: \$ROLLBACK_RESULT"
echo "Backup used: \$BACKUP_DIR"
echo

[ "\$ROLLBACK_RESULT" = "SUCCESS" ] && exit 0
exit 1
ROLLBACK_EOF

chmod 700 "$ROLLBACK_FILE"
ok "$ROLLBACK_FILE"

cat > "$REAPPLY_FILE" <<REAPPLY_EOF
#!/usr/bin/env bash
# Reapply generated by install-emby-custom.sh on $TIMESTAMP.
# Re-copies what was staged in custom/dashboard-ui/ and reinstalls the
# CustomCss via API. Reads the credentials from api.env at run time; never
# embeds them. It has its own lightweight backup (proportional to what it
# touches: 6 JS + index.html + CustomCss) and the same exit code contract
# as the main installer: 0=SUCCESS, 1=FAILED, 2=DEGRADED. A failure halfway
# through reverts with the same SUCCESS/PARTIAL/FAILED criteria as
# rollback() in install-emby-custom.sh -- it is not a packaged cp.
set -Eeuo pipefail

CONTAINER=$(shell_single_quote "$CONTAINER")
EMBY_URL=$(shell_single_quote "$EMBY_URL")
BASE=$(shell_single_quote "$BASE")
CUSTOM=$(shell_single_quote "$DASHBOARD_UI")
INDEX=$(shell_single_quote "$INDEX_CONTAINER_PATH")
DASHBOARD_DIR=$(shell_single_quote "$DASHBOARD_CONTAINER_DIR")
SECRETS_FILE=$(shell_single_quote "$SECRETS_FILE")
EMBY_BRANDING_GET_PATH=$(shell_single_quote "$EMBY_BRANDING_GET_PATH")
EMBY_BRANDING_POST_PATH=$(shell_single_quote "$EMBY_BRANDING_POST_PATH")
CSS_URL=$(shell_single_quote "$CSS_URL")
CSS_SOURCE_FILE=$(shell_single_quote "$CSS_SOURCE")
TESTED_EMBY_VERSION=$(shell_single_quote "$TESTED_EMBY_VERSION")
# theme     -> re-copies the patched skinmanager.js + theme.css and leaves
#              the Branding CustomCss empty (the theme is loaded from there).
# customcss -> previous behavior: CSS embedded in Branding.
THEME_MODE=$(shell_single_quote "$THEME_MODE")
SKINMANAGER_REL=$(shell_single_quote "$SKINMANAGER_REL")
THEME_CSS_REL=$(shell_single_quote "$THEME_CSS_REL")
SKINMANAGER=$(shell_single_quote "$SKINMANAGER_CONTAINER_PATH")
THEME_CSS=$(shell_single_quote "$THEME_CSS_CONTAINER_PATH")

JS_NAMES=(
$JS_NAMES_BASH_ARRAY
)

REAPPLY_STARTED=0
ROLLBACK_RUNNING=0
ROLLBACK_RESULT="NOT_NEEDED"
CSS_INSTALL_FAILED=0
REAPPLY_BACKUP_DIR="\$(mktemp -d)"

$SHARED_RESTORE_FUNCTIONS

rollback_reapply() {
    if [ "\$ROLLBACK_RUNNING" = "1" ]; then
        return 0
    fi
    ROLLBACK_RUNNING=1

    echo
    echo "=================================================================="
    echo " AUTOMATIC ROLLBACK (reapply)"
    echo "=================================================================="
    echo

    if ! docker inspect "\$CONTAINER" >/dev/null 2>&1; then
        echo "WARNING: container \$CONTAINER no longer exists; rollback is not possible."
        ROLLBACK_RESULT="FAILED"
        return 0
    fi

    HAD_FAILURE=0
    HAD_SUCCESS=0

    if [ -f "\$REAPPLY_BACKUP_DIR/index.html" ]; then
        if restore_or_warn_file "\$CONTAINER" "\$REAPPLY_BACKUP_DIR/index.html" "\$INDEX" "index.html"; then
            HAD_SUCCESS=1
        else
            RC=\$?
            [ "\$RC" = "1" ] && HAD_FAILURE=1
        fi
    fi

    for JS in "\${JS_NAMES[@]}"; do
        if [ -f "\$REAPPLY_BACKUP_DIR/\$JS" ]; then
            if restore_or_warn_file "\$CONTAINER" "\$REAPPLY_BACKUP_DIR/\$JS" "\$DASHBOARD_DIR/\$JS" "\$JS"; then
                HAD_SUCCESS=1
            else
                RC=\$?
                [ "\$RC" = "1" ] && HAD_FAILURE=1
            fi
        else
            docker exec "\$CONTAINER" sh -c "rm -f '\$DASHBOARD_DIR/\$JS'" 2>/dev/null || true
        fi
    done

    if [ "\$THEME_MODE" = "theme" ]; then
        if [ -f "\$REAPPLY_BACKUP_DIR/skinmanager.js" ]; then
            if restore_or_warn_file "\$CONTAINER" "\$REAPPLY_BACKUP_DIR/skinmanager.js" "\$SKINMANAGER" "skinmanager.js"; then
                HAD_SUCCESS=1
            else
                RC=\$?
                [ "\$RC" = "1" ] && HAD_FAILURE=1
            fi
        fi
        if restore_or_remove_file "\$CONTAINER" "\$REAPPLY_BACKUP_DIR/theme.css" "\$THEME_CSS" "theme.css"; then
            HAD_SUCCESS=1
        else
            RC=\$?
            [ "\$RC" = "1" ] && HAD_FAILURE=1
        fi
    fi

    if [ -f "\$REAPPLY_BACKUP_DIR/branding-before.json" ] && [ -f "\$SECRETS_FILE" ]; then
        # shellcheck disable=SC1090
        source "\$SECRETS_FILE"
        TOKEN_CONFIG="\$(mktemp)"
        chmod 600 "\$TOKEN_CONFIG"
        printf 'header = "X-Emby-Token: %s"\n' "\$(curl_config_escape "\${EMBY_API_KEY:-}")" > "\$TOKEN_CONFIG"
        if restore_css_from_backup "\$REAPPLY_BACKUP_DIR/branding-before.json" "\$EMBY_URL" "\$EMBY_BRANDING_POST_PATH" "\$TOKEN_CONFIG"; then
            HAD_SUCCESS=1
        else
            HAD_FAILURE=1
        fi
        rm -f "\$TOKEN_CONFIG"
    fi

    if [ "\$HAD_FAILURE" = "1" ]; then
        if [ "\$HAD_SUCCESS" = "1" ]; then
            ROLLBACK_RESULT="PARTIAL"
        else
            ROLLBACK_RESULT="FAILED"
        fi
    else
        ROLLBACK_RESULT="SUCCESS"
    fi

    echo
    echo "Automatic rollback (reapply): \$ROLLBACK_RESULT"
    echo "Backup used: \$REAPPLY_BACKUP_DIR (kept for inspection)"
    return 0
}

on_error_reapply() {
    ORIGINAL_EXIT_CODE=\$?
    echo
    echo "ERROR (reapply). Original exit code: \$ORIGINAL_EXIT_CODE"
    if [ "\$REAPPLY_STARTED" = "1" ]; then
        rollback_reapply || true
        echo "Result: REAPPLY_RESULT=FAILED ROLLBACK_RESULT=\$ROLLBACK_RESULT"
    fi
    exit 1
}

on_interrupt_reapply() {
    echo
    echo "CANCELLED."
    if [ "\$REAPPLY_STARTED" = "1" ]; then
        rollback_reapply || true
        echo "Result: REAPPLY_RESULT=FAILED ROLLBACK_RESULT=\$ROLLBACK_RESULT"
        exit 1
    fi
    exit 0
}

trap on_error_reapply ERR
trap on_interrupt_reapply INT TERM

echo
echo "=================================================================="
echo " REAPPLY - $TIMESTAMP"
echo "=================================================================="
echo

docker inspect "\$CONTAINER" >/dev/null 2>&1 || {
    echo "ERROR: container \$CONTAINER does not exist."
    exit 1
}

[ "\$(docker inspect "\$CONTAINER" -f '{{.State.Running}}')" = "true" ] || {
    echo "ERROR: container \$CONTAINER is not running."
    exit 1
}

# reapply is documented as the typical recovery path after TrueNAS
# recreates the container (e.g. after updating the Emby app) -- which is
# exactly the moment when the Emby version most likely changed. It warns
# (does not block) if it differs from the tested one, just like the main
# installer.
REAPPLY_EMBY_VERSION="unknown"
REAPPLY_VERSION_TMP="\$(mktemp)"
if curl --silent --show-error --location --output "\$REAPPLY_VERSION_TMP" \\
    --connect-timeout 10 --max-time 20 \\
    "\$EMBY_URL/emby/System/Info/Public" 2>/dev/null
then
    REAPPLY_DETECTED_VERSION="\$(grep -oE '"Version":"[^"]*"' "\$REAPPLY_VERSION_TMP" | head -n1 | cut -d'"' -f4 || true)"
    [ -n "\$REAPPLY_DETECTED_VERSION" ] && REAPPLY_EMBY_VERSION="\$REAPPLY_DETECTED_VERSION"
fi
rm -f "\$REAPPLY_VERSION_TMP"
echo "Emby server: \$REAPPLY_EMBY_VERSION (this script was tested against \$TESTED_EMBY_VERSION)"
if [ "\$REAPPLY_EMBY_VERSION" != "unknown" ] && [ "\$REAPPLY_EMBY_VERSION" != "\$TESTED_EMBY_VERSION" ]; then
    echo "WARNING: the Emby version changed from the tested one -- the addons/index.html about to be reapplied were edited for \$TESTED_EMBY_VERSION."
fi

for JS in "\${JS_NAMES[@]}"; do
    [ -s "\$CUSTOM/\$JS" ] || {
        echo "ERROR: missing \$CUSTOM/\$JS"
        exit 1
    }
done
[ -s "\$CUSTOM/index.html" ] || {
    echo "ERROR: missing \$CUSTOM/index.html"
    exit 1
}
if [ "\$THEME_MODE" = "theme" ]; then
    for REL in "\$SKINMANAGER_REL" "\$THEME_CSS_REL"; do
        [ -s "\$CUSTOM/\$REL" ] || {
            echo "ERROR: missing \$CUSTOM/\$REL (required for the theme)"
            exit 1
        }
    done
fi

echo "Backing up the current container state (lightweight, so this reapply can be reverted)..."
mkdir -p "\$REAPPLY_BACKUP_DIR"
if docker exec "\$CONTAINER" sh -c "test -f '\$INDEX'" 2>/dev/null; then
    docker cp "\$CONTAINER:\$INDEX" "\$REAPPLY_BACKUP_DIR/index.html" 2>/dev/null || true
fi
if [ "\$THEME_MODE" = "theme" ]; then
    if docker exec "\$CONTAINER" sh -c "test -f '\$SKINMANAGER'" 2>/dev/null; then
        docker cp "\$CONTAINER:\$SKINMANAGER" "\$REAPPLY_BACKUP_DIR/skinmanager.js" 2>/dev/null || true
    fi
    if docker exec "\$CONTAINER" sh -c "test -f '\$THEME_CSS'" 2>/dev/null; then
        docker cp "\$CONTAINER:\$THEME_CSS" "\$REAPPLY_BACKUP_DIR/theme.css" 2>/dev/null || true
    fi
fi
for JS in "\${JS_NAMES[@]}"; do
    if docker exec "\$CONTAINER" sh -c "test -f '\$DASHBOARD_DIR/\$JS'" 2>/dev/null; then
        docker cp "\$CONTAINER:\$DASHBOARD_DIR/\$JS" "\$REAPPLY_BACKUP_DIR/\$JS" 2>/dev/null || true
    fi
done
if [ -f "\$SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    source "\$SECRETS_FILE"
    BACKUP_TOKEN_CONFIG="\$(mktemp)"
    chmod 600 "\$BACKUP_TOKEN_CONFIG"
    printf 'header = "X-Emby-Token: %s"\n' "\$(curl_config_escape "\${EMBY_API_KEY:-}")" > "\$BACKUP_TOKEN_CONFIG"
    BACKUP_GET_STATUS="\$(
        curl --silent --show-error --location \\
            -K "\$BACKUP_TOKEN_CONFIG" \\
            --header "Accept: application/json" \\
            --output "\$REAPPLY_BACKUP_DIR/branding-before.json" --write-out '%{http_code}' \\
            "\$EMBY_URL\$EMBY_BRANDING_GET_PATH" 2>/dev/null || true
    )"
    rm -f "\$BACKUP_TOKEN_CONFIG"
    # Unlike index.html/the addons (where "does not exist yet" is a
    # legitimate case, see 'test -f' above), Branding/Configuration always
    # exists in Emby -- a failure here is a real failure, not something to
    # swallow silently with a blind '|| true'.
    if [ "\$BACKUP_GET_STATUS" != "200" ]; then
        echo "  WARNING: could not back up CustomCss before reapplying (HTTP \${BACKUP_GET_STATUS:-no response}). Response: \$(http_body_snippet "\$REAPPLY_BACKUP_DIR/branding-before.json")"
        rm -f "\$REAPPLY_BACKUP_DIR/branding-before.json"
    fi
fi
echo "  OK backup at \$REAPPLY_BACKUP_DIR"

REAPPLY_STARTED=1

echo "Copying addons..."
for JS in "\${JS_NAMES[@]}"; do
    docker cp "\$CUSTOM/\$JS" "\$CONTAINER:\$DASHBOARD_DIR/\$JS"
    echo "  OK \$JS"
done

echo "Copying index.html..."
docker cp "\$CUSTOM/index.html" "\$CONTAINER:\$INDEX"

if [ "\$THEME_MODE" = "theme" ]; then
    echo "Copying theme (skinmanager.js + theme.css)..."
    THEME_CSS_DIR="\$(dirname "\$THEME_CSS")"
    docker exec "\$CONTAINER" sh -c "mkdir -p '\$THEME_CSS_DIR'"
    docker cp "\$CUSTOM/\$SKINMANAGER_REL" "\$CONTAINER:\$SKINMANAGER"
    docker cp "\$CUSTOM/\$THEME_CSS_REL" "\$CONTAINER:\$THEME_CSS"
    docker exec "\$CONTAINER" chmod 644 "\$SKINMANAGER" "\$THEME_CSS"
    echo "  OK skinmanager.js + theme.css"
fi

docker exec "\$CONTAINER" chmod 644 "\$INDEX"
for JS in "\${JS_NAMES[@]}"; do
    docker exec "\$CONTAINER" chmod 644 "\$DASHBOARD_DIR/\$JS"
done

if [ -f "\$SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    source "\$SECRETS_FILE"
    if [ -n "\${EMBY_API_KEY:-}" ]; then
        if [ "\$THEME_MODE" = "theme" ] || [ -s "\$CSS_SOURCE_FILE" ]; then
            if [ "\$THEME_MODE" = "theme" ]; then
                # In theme mode the CSS lives in theme.css; the Branding
                # CustomCss must be left EMPTY (otherwise it would override
                # the admin dashboard again).
                echo "Leaving Branding Custom CSS empty (the theme is loaded from skinmanager.js)..."
                REINSTALL_CSS_CONTENT=""
            else
                echo "Reinstalling Custom CSS..."
                IFS= read -r -d '' REINSTALL_CSS_CONTENT < "\$CSS_SOURCE_FILE" || true
            fi
            REINSTALL_TOKEN_CONFIG="\$(mktemp)"
            chmod 600 "\$REINSTALL_TOKEN_CONFIG"
            printf 'header = "X-Emby-Token: %s"\n' "\$(curl_config_escape "\$EMBY_API_KEY")" > "\$REINSTALL_TOKEN_CONFIG"
            REINSTALL_PAYLOAD="\$(mktemp)"
            printf '{"CustomCss": "%s"}' "\$(json_escape "\$REINSTALL_CSS_CONTENT")" > "\$REINSTALL_PAYLOAD"
            REINSTALL_OUT="\$(mktemp)"
            REINSTALL_STATUS="\$(
                curl --silent --show-error --location --request POST \\
                    -K "\$REINSTALL_TOKEN_CONFIG" \\
                    --header "Content-Type: application/json" \\
                    --header "Accept: application/json" \\
                    --data-binary "@\$REINSTALL_PAYLOAD" \\
                    --output "\$REINSTALL_OUT" --write-out '%{http_code}' \\
                    "\$EMBY_URL\$EMBY_BRANDING_POST_PATH" 2>/dev/null || true
            )"
            rm -f "\$REINSTALL_TOKEN_CONFIG" "\$REINSTALL_PAYLOAD"
            case "\$REINSTALL_STATUS" in
                2??)
                    echo "  OK Custom CSS reinstalled."
                    ;;
                *)
                    echo "  WARNING: could not reinstall Custom CSS (HTTP \${REINSTALL_STATUS:-no response}). Response: \$(http_body_snippet "\$REINSTALL_OUT")"
                    CSS_INSTALL_FAILED=1
                    ;;
            esac
            rm -f "\$REINSTALL_OUT"
        else
            echo "  WARNING: downloaded CSS not found (\$CSS_SOURCE_FILE); skipping Custom CSS reinstallation."
            CSS_INSTALL_FAILED=1
        fi
    fi
else
    echo "WARNING: \$SECRETS_FILE not found; skipping Custom CSS reinstallation."
fi

echo
echo "Verifying..."
for JS in "\${JS_NAMES[@]}"; do
    docker exec "\$CONTAINER" sh -c "test -s '\$DASHBOARD_DIR/\$JS'"
    docker exec "\$CONTAINER" sh -c "grep -qF '\$JS' '\$INDEX'"
    echo "  OK \$JS"
done
if [ "\$THEME_MODE" = "theme" ]; then
    for PAIR in "\$SKINMANAGER_REL:\$SKINMANAGER" "\$THEME_CSS_REL:\$THEME_CSS"; do
        REL="\${PAIR%%:*}"
        DEST="\${PAIR#*:}"
        EXPECTED="\$(sha256sum "\$CUSTOM/\$REL" | awk '{print \$1}')"
        ACTUAL="\$(docker exec "\$CONTAINER" sh -c "sha256sum '\$DEST'" | awk '{print \$1}')"
        [ "\$EXPECTED" = "\$ACTUAL" ] || {
            echo "ERROR: \$REL: the installed SHA256 does not match the staged file."
            exit 1
        }
        echo "  OK \$REL (sha256 OK)"
    done
fi

REAPPLY_STARTED=0
rm -rf "\$REAPPLY_BACKUP_DIR"

echo
if [ "\$CSS_INSTALL_FAILED" = "1" ]; then
    echo "REAPPLY COMPLETED WITH DEGRADATION (CSS failed, not critical). Result: DEGRADED"
    exit 2
else
    echo "REAPPLY COMPLETED. Result: SUCCESS"
    exit 0
fi
REAPPLY_EOF

chmod 700 "$REAPPLY_FILE"
ok "$REAPPLY_FILE"

# ==============================================================================
# 15. INSTALL
# ==============================================================================

section "PHASE 8/9 - Install"

step "Verifying container identity before installing"

CURRENT_CONTAINER_ID="$(docker inspect "$CONTAINER" -f '{{.Id}}' 2>/dev/null || true)"
[ -n "$CURRENT_CONTAINER_ID" ] && [ "$CURRENT_CONTAINER_ID" = "$CONTAINER_ID" ] \
    || die_precheck "Container '$CONTAINER' changed identity right before installing (was it recreated?). The backup already taken would not belong to this container; nothing is installed. Run the script again from scratch."
ok "Container '$CONTAINER' is still the same instance detected earlier (${CONTAINER_ID:0:12})."

INSTALL_STARTED=1

step "Copying addons into the container"
for JS in "${JS_NAMES[@]}"; do
    docker cp "$DASHBOARD_UI/$JS" "$CONTAINER:$DASHBOARD_CONTAINER_DIR/$JS"
    docker exec "$CONTAINER" sh -c "chmod 644 '$DASHBOARD_CONTAINER_DIR/$JS'"
    ok "$JS installed."
done

step "Copying index.html into the container"
docker cp "$STAGED_INDEX" "$CONTAINER:$INDEX_CONTAINER_PATH"
docker exec "$CONTAINER" sh -c "chmod 644 '$INDEX_CONTAINER_PATH'"
ok "index.html installed."

if [ "$THEME_MODE" = "theme" ]; then
    step "Installing theme $THEME_NAME (patched skinmanager.js + theme.css)"
    docker exec "$CONTAINER" sh -c "mkdir -p '$(dirname "$THEME_CSS_CONTAINER_PATH")'"
    docker cp "$STAGED_SKINMANAGER" "$CONTAINER:$SKINMANAGER_CONTAINER_PATH"
    docker cp "$STAGED_THEME_CSS" "$CONTAINER:$THEME_CSS_CONTAINER_PATH"
    docker exec "$CONTAINER" sh -c "chmod 644 '$SKINMANAGER_CONTAINER_PATH' '$THEME_CSS_CONTAINER_PATH'"
    ok "$SKINMANAGER_REL and $THEME_CSS_REL installed."
fi

if [ "$THEME_MODE" = "theme" ]; then
    step "Clearing the Branding CustomCss (the theme is loaded from skinmanager.js)"
else
    step "Installing CustomCss via API (embedded content, no @import, not as a file)"
fi

# This is the only truly destructive step in the whole script (see README,
# "Before you run this"): it completely replaces Emby's current CustomCss,
# it does not merge it (in theme mode it leaves it empty, which is what is
# needed so that Embymalism does NOT override the admin panel). It is
# recoverable (branding-before.json is already backed up and the rollback
# restores it), but until a rollback is done, any other custom CSS that was
# there is gone from Emby. In --silent mode there is no prompt (it never
# calls 'read'), like the rest of the script; there, having passed --silent
# is the implicit confirmation.
CSS_SKIPPED_BY_USER=0
if [ "$SILENT_MODE" != "1" ]; then
    echo
    warn "This step completely REPLACES Emby's current Custom CSS."
    warn "If you had other custom CSS configured, it is lost from Emby"
    warn "(not from disk: it can be recovered with $ROLLBACK_FILE)."
    CSS_CONFIRM=""
    read -rp "Replace the Custom CSS now? [y/N]: " CSS_CONFIRM || CSS_CONFIRM=""
    case "$CSS_CONFIRM" in
        s|S|si|Si|SI|y|Y|yes|YES)
            ;;
        *)
            CSS_INSTALL_FAILED=1
            CSS_SKIPPED_BY_USER=1
            warn "Custom CSS install SKIPPED by user decision (not a failure). The JS addons are installed anyway."
            ;;
    esac
fi

if [ "$CSS_SKIPPED_BY_USER" != "1" ]; then
    # The actual CONTENT of the CSS already downloaded and hash-verified in
    # PHASE 5/9 ($CSS_SOURCE, $CSS_HASH) is embedded -- not an
    # '@import url(...)' pointing at GitHub. With the @import, every load of
    # the Emby UI depended on raw.githubusercontent.com answering at that
    # moment; by embedding the content, Emby serves the CSS stored in its
    # own config, without that external dependency on the critical path of
    # every page. Note: the Embymalism CSS itself does its own @import of
    # Google Fonts and references imgur images -- this removes ONE external
    # dependency (GitHub), not all the ones the theme brings.
    CSS_PAYLOAD_FILE="$CUSTOM_ROOT/branding-payload.json.tmp"
    # 'CSS_CONTENT="$(cat "$CSS_SOURCE")"' looks harmless but strips any
    # trailing newline from the file -- a command substitution ALWAYS does,
    # no matter how many newlines the original has. 'IFS= read -r -d ""'
    # reads the whole file as is, byte by byte, so the hash computed in
    # PHASE 5/9 ($CSS_HASH, over the real file) remains comparable later
    # against what Emby actually stored.
    if [ "$THEME_MODE" = "theme" ]; then
        CSS_CONTENT=""
    else
        IFS= read -r -d '' CSS_CONTENT < "$CSS_SOURCE" || true
    fi
    printf '{"CustomCss": "%s"}' "$(json_escape "$CSS_CONTENT")" > "$CSS_PAYLOAD_FILE"
    # What PHASE 9/9 must find in Branding: empty in theme mode, the full
    # CSS in customcss mode.
    CSS_EXPECTED_HASH="$(printf '%s' "$CSS_CONTENT" | sha256sum | awk '{print $1}')"
    CSS_EXPECTED_SIZE="${#CSS_CONTENT}"

    CSS_INSTALL_OUT="$(mktemp "$CUSTOM_ROOT/.branding-install.XXXXXX.tmp")"
    CSS_INSTALL_STATUS="$(
        curl --silent --show-error --location --request POST \
            --connect-timeout 10 --max-time 30 \
            -K "$EMBY_TOKEN_CURL_CONFIG" \
            --header "Content-Type: application/json" \
            --header "Accept: application/json" \
            --data-binary "@$CSS_PAYLOAD_FILE" \
            --output "$CSS_INSTALL_OUT" --write-out '%{http_code}' \
            "$EMBY_URL$EMBY_BRANDING_POST_PATH" 2>/dev/null || true
    )"
    case "$CSS_INSTALL_STATUS" in
        2??)
            if [ "$THEME_MODE" = "theme" ]; then
                ok "Branding Custom CSS cleared via API."
            else
                ok "Custom CSS installed via API."
            fi
            ;;
        *)
            CSS_INSTALL_FAILED=1
            warn "Custom CSS install via API failed (HTTP ${CSS_INSTALL_STATUS:-no response}). Response: $(http_body_snippet "$CSS_INSTALL_OUT")"
            warn "The JS addons already installed are NOT reverted (non-critical failure)."
            warn "Manual retry: re-run this script, or run the 'Reinstalling Custom CSS' block of $REAPPLY_FILE."
            ;;
    esac
    rm -f "$CSS_INSTALL_OUT" "$CSS_PAYLOAD_FILE"
fi

# ==============================================================================
# 16. POST-INSTALL VERIFICATION
# ==============================================================================

section "PHASE 9/9 - Verification"

step "Files in the container"

INSTALLED_HASHES="$BACKUP_DIR/installed-SHA256SUMS.txt"
rm -f "$INSTALLED_HASHES"

for JS in "${JS_NAMES[@]}"; do
    docker exec "$CONTAINER" sh -c "test -s '$DASHBOARD_CONTAINER_DIR/$JS'" \
        || die_critical "$JS does not exist (or is empty) in the container after the install."

    CONTAINER_SIZE="$(docker exec "$CONTAINER" sh -c "wc -c < '$DASHBOARD_CONTAINER_DIR/$JS'" | tr -d ' \r')"
    [ "$CONTAINER_SIZE" -gt 100 ] \
        || die_critical "$JS ended up with a suspicious size in the container ($CONTAINER_SIZE bytes)."

    EXPECTED_HASH="$(sha256sum "$DASHBOARD_UI/$JS" | awk '{print $1}')"
    ACTUAL_HASH="$(docker exec "$CONTAINER" sh -c "sha256sum '$DASHBOARD_CONTAINER_DIR/$JS'" | awk '{print $1}')"

    [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ] \
        || die_critical "$JS: installed SHA256 does not match the expected one (possible corruption in docker cp)."

    docker exec "$CONTAINER" sh -c "grep -q 'EMBY_API_KEY' '$DASHBOARD_CONTAINER_DIR/$JS'" \
        && die_critical "SECURITY: EMBY_API_KEY appears in $JS inside the container after installing." \
        || true

    docker exec "$CONTAINER" sh -c "grep -qF '$JS' '$INDEX_CONTAINER_PATH'" \
        || die_critical "$JS is not referenced in index.html inside the container."

    echo "$ACTUAL_HASH  $JS" >> "$INSTALLED_HASHES"
    ok "$JS ($CONTAINER_SIZE bytes, sha256 OK, EMBY_API_KEY absent, referenced in index.html)"
done

docker exec "$CONTAINER" sh -c "test -s '$INDEX_CONTAINER_PATH'" \
    || die_critical "index.html does not exist in the container after the install."

INDEX_HASH="$(docker exec "$CONTAINER" sh -c "sha256sum '$INDEX_CONTAINER_PATH'" | awk '{print $1}')"
echo "$INDEX_HASH  index.html" >> "$INSTALLED_HASHES"
ok "index.html present (sha256 $INDEX_HASH)"

if [ "$THEME_MODE" = "theme" ]; then
    step "Theme $THEME_NAME in the container"

    for PAIR in "$STAGED_SKINMANAGER:$SKINMANAGER_CONTAINER_PATH:skinmanager.js" "$STAGED_THEME_CSS:$THEME_CSS_CONTAINER_PATH:theme.css"; do
        STAGED_PATH="${PAIR%%:*}"
        REST="${PAIR#*:}"
        DEST_PATH="${REST%%:*}"
        LABEL="${REST#*:}"
        docker exec "$CONTAINER" sh -c "test -s '$DEST_PATH'" \
            || die_critical "$LABEL does not exist (or is empty) in the container after the install."
        EXPECTED_HASH="$(sha256sum "$STAGED_PATH" | awk '{print $1}')"
        ACTUAL_HASH="$(docker exec "$CONTAINER" sh -c "sha256sum '$DEST_PATH'" | awk '{print $1}')"
        [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ] \
            || die_critical "$LABEL: installed SHA256 does not match the expected one (possible corruption in docker cp)."
        echo "$ACTUAL_HASH  $LABEL" >> "$INSTALLED_HASHES"
    done

    # Structural verification over what ended up INSIDE the container (not
    # over the staging copy): the entry exactly once, right before the Light
    # one, and no other byte different from Emby's baseline.
    SKINMANAGER_VERIFY_TMP="$(mktemp "$CUSTOM_ROOT/.skinmanager-verify.XXXXXX.tmp")"
    docker cp "$CONTAINER:$SKINMANAGER_CONTAINER_PATH" "$SKINMANAGER_VERIFY_TMP"
    theme_verify_patched "$SKINMANAGER_VERIFY_TMP" \
        || { rm -f "$SKINMANAGER_VERIFY_TMP"; die_critical "The installed $SKINMANAGER_REL fails the structural verification of the '$THEME_NAME' entry."; }
    theme_strip_entry "$SKINMANAGER_VERIFY_TMP"
    cmp -s "$SKINMANAGER_VERIFY_TMP" "$ORIGINAL_SKINMANAGER" \
        || { rm -f "$SKINMANAGER_VERIFY_TMP"; die_critical "The installed $SKINMANAGER_REL differs from Emby's original in something other than our entry."; }
    rm -f "$SKINMANAGER_VERIFY_TMP"
    ok "skinmanager.js: '$THEME_NAME' entry present exactly once; with it removed, byte-for-byte identical to Emby's original."
    ok "theme.css ($THEME_ID): sha256 OK, identical to the downloaded $CSS_NAME."
fi

step "Custom CSS"

if [ "$CSS_INSTALL_FAILED" = "1" ]; then
    if [ "$CSS_SKIPPED_BY_USER" = "1" ]; then
        warn "Skipping Custom CSS verification: the user chose not to replace it."
    else
        warn "Skipping Custom CSS verification: the API install failed in the previous step."
    fi
else
    CSS_VERIFY_TMP="$(mktemp "$CUSTOM_ROOT/.branding-verify.XXXXXX.tmp")"
    CSS_VERIFY_STATUS="$(
        curl --silent --show-error --location \
            -K "$EMBY_TOKEN_CURL_CONFIG" \
            --header "Accept: application/json" \
            --output "$CSS_VERIFY_TMP" --write-out '%{http_code}' \
            "$EMBY_URL$EMBY_BRANDING_GET_PATH" 2>/dev/null || true
    )"

    if [ "$CSS_VERIFY_STATUS" != "200" ]; then
        CSS_VERIFY_SNIPPET="$(http_body_snippet "$CSS_VERIFY_TMP")"
        rm -f "$CSS_VERIFY_TMP"
        die_critical "Could not verify Branding/Configuration after installing the CSS (HTTP ${CSS_VERIFY_STATUS:-no response}). Response: ${CSS_VERIFY_SNIPPET:-(empty)}"
    fi

    if [ "$HAS_JQ" = "1" ]; then
        # Exact verification: the JSON is really decoded (the CSS carries
        # escaped quotes/backslashes/newlines -- a substring grep is not
        # enough to compare content byte by byte) and the hash is compared
        # against the one computed when it was downloaded in PHASE 5/9.
        # This proves that what Emby serves TODAY is exactly what was
        # installed, not just that "something" got stored.
        # '-j' (join), NOT '-r': '-r' prints a newline AFTER the extracted
        # string (normal jq behavior, not a bug), which sha256sum would count
        # as part of the content -- that produced a false mismatch (and an
        # unnecessary rollback) even when the installed CSS was exactly
        # equal, byte by byte, to the downloaded one.
        CSS_VERIFY_HASH="$(jq -j '.CustomCss // empty' "$CSS_VERIFY_TMP" 2>/dev/null | sha256sum | awk '{print $1}')"
        if [ "$CSS_VERIFY_HASH" = "$CSS_EXPECTED_HASH" ]; then
            if [ "$THEME_MODE" = "theme" ]; then
                ok "Branding Custom CSS verified via API: empty, as expected in theme mode."
            else
                ok "Custom CSS verified via API (content matches the download byte by byte, sha256 $CSS_HASH)."
            fi
        else
            CSS_VERIFY_SNIPPET="$(http_body_snippet "$CSS_VERIFY_TMP")"
            rm -f "$CSS_VERIFY_TMP"
            die_critical "The installed Custom CSS does not match what was expected (expected sha256 $CSS_EXPECTED_HASH, got ${CSS_VERIFY_HASH:-empty}). Response: ${CSS_VERIFY_SNIPPET:-(empty)}"
        fi
    else
        # Without jq there is no reliable way to decode the JSON to compare
        # exact bytes -- the size is compared as a signal that the response
        # was not truncated, instead of verifying nothing. JSON escaping
        # never shrinks the size, so a response smaller than the source CSS
        # is, in practice, always a sign of truncation.
        CSS_VERIFY_SIZE="$(wc -c < "$CSS_VERIFY_TMP" | tr -d ' ')"
        CSS_SOURCE_SIZE="$CSS_EXPECTED_SIZE"
        if [ "$CSS_VERIFY_SIZE" -ge "$CSS_SOURCE_SIZE" ]; then
            ok "Custom CSS verified via API (response size consistent with what was installed; install jq for a byte-by-byte comparison)."
        else
            CSS_VERIFY_SNIPPET="$(http_body_snippet "$CSS_VERIFY_TMP")"
            rm -f "$CSS_VERIFY_TMP"
            die_critical "The installed Custom CSS looks truncated: the response has $CSS_VERIFY_SIZE bytes, at least $CSS_SOURCE_SIZE were expected. Response: ${CSS_VERIFY_SNIPPET:-(empty)}"
        fi
    fi
    rm -f "$CSS_VERIFY_TMP"
fi

step "Reviews.js (language and types)"

grep -Eq "const[[:space:]]+PRIMARY_LANGUAGE[[:space:]]*=[[:space:]]*[\"']$(sed_escape_pattern "$REVIEWS_PRIMARY_LANGUAGE")[\"']" "$REVIEWS" \
    || die_critical "Installed Reviews.js does not have PRIMARY_LANGUAGE=$REVIEWS_PRIMARY_LANGUAGE."
ok "PRIMARY_LANGUAGE=$REVIEWS_PRIMARY_LANGUAGE"

grep -Eq "const[[:space:]]+MAX_REVIEWS[[:space:]]*=[[:space:]]*${REVIEWS_MAX_REVIEWS}[[:space:]]*;" "$REVIEWS" \
    || die_critical "Installed Reviews.js does not have a numeric MAX_REVIEWS=$REVIEWS_MAX_REVIEWS."
ok "MAX_REVIEWS=$REVIEWS_MAX_REVIEWS (numeric)"

step "Spotlight.js (mobile video)"

grep -Eq "enableMobileVideo[[:space:]]*:[[:space:]]*${SPOTLIGHT_ENABLE_MOBILE_VIDEO}[[:space:]]*,?" "$SPOTLIGHT" \
    || die_critical "Installed Spotlight.js does not have enableMobileVideo=$SPOTLIGHT_ENABLE_MOBILE_VIDEO."
ok "enableMobileVideo=$SPOTLIGHT_ENABLE_MOBILE_VIDEO"

INSTALL_STARTED=0

# Only now -- PHASE 9/9 has already verified that the 6 addons ended up
# byte-for-byte as expected -- is this run's hash baseline promoted to
# KNOWN_HASHES_FILE. Before this point, any die_precheck/die_critical leaves
# the previous baseline intact (see PHASE 5/9): a failure halfway through
# never makes --require-known-hashes "forget" the good hash of an addon
# that was never installed.
mv "$KNOWN_HASHES_NEW" "$KNOWN_HASHES_FILE"

# ==============================================================================
# 17. FINAL ARTIFACTS: manifest.json and config.json
# ==============================================================================

step "Generating manifest and config.json"

CSS_STATUS_JSON="installed"
CSS_STATUS_TEXT="installed and verified"
if [ "$THEME_MODE" = "theme" ]; then
    CSS_STATUS_JSON="installed_as_theme"
    CSS_STATUS_TEXT="Branding empty (verified); the CSS is loaded as a theme from $THEME_CSS_REL"
fi
if [ "$CSS_INSTALL_FAILED" = "1" ]; then
    if [ "$CSS_SKIPPED_BY_USER" = "1" ]; then
        CSS_STATUS_JSON="skipped_by_user"
        CSS_STATUS_TEXT="skipped by user decision"
    else
        CSS_STATUS_JSON="failed_non_critical"
        CSS_STATUS_TEXT="FAILED (non-critical, see above)"
    fi
    INSTALL_RESULT="DEGRADED"
else
    INSTALL_RESULT="SUCCESS"
fi

{
    echo "{"
    echo "  \"install_result\": \"$(json_escape "$INSTALL_RESULT")\","
    echo "  \"timestamp\": \"$(json_escape "$TIMESTAMP")\","
    echo "  \"container\": \"$(json_escape "$CONTAINER")\","
    echo "  \"container_id\": \"$(json_escape "$CONTAINER_ID")\","
    echo "  \"image\": \"$(json_escape "$CONTAINER_IMAGE")\","
    echo "  \"emby_url\": \"$(json_escape "$EMBY_URL")\","
    echo "  \"emby_server_version\": \"$(json_escape "$EMBY_SERVER_VERSION")\","
    echo "  \"tested_emby_version\": \"$(json_escape "$TESTED_EMBY_VERSION")\","
    echo "  \"base\": \"$(json_escape "$BASE")\","
    echo "  \"backup_dir\": \"$(json_escape "$BACKUP_DIR")\","
    echo "  \"backup_tgz\": \"$(json_escape "$BACKUP_TGZ")\","
    echo "  \"css_status\": \"$CSS_STATUS_JSON\","
    echo "  \"css_url\": \"$(json_escape "$CSS_URL")\","
    echo "  \"css_pin_ref\": \"$(json_escape "$CSS_PIN_REF")\","
    echo "  \"theme\": {"
    echo "    \"mode\": \"$(json_escape "$THEME_MODE")\","
    echo "    \"id\": \"$(json_escape "$THEME_ID")\","
    echo "    \"name\": \"$(json_escape "$THEME_NAME")\","
    echo "    \"skinmanager_patched\": $([ "$THEME_MODE" = "theme" ] && echo true || echo false),"
    echo "    \"default_for_all_users\": $([ "$THEME_MODE" = "theme" ] && [ "$THEME_SET_AS_DEFAULT" = "1" ] && echo true || echo false),"
    echo "    \"fallback_reason\": \"$(json_escape "$THEME_FALLBACK_REASON")\""
    echo "  },"
    echo "  \"cors_proxy_url\": \"$(json_escape "$CORS_PROXY_URL")\","
    echo "  \"api_proxy_url\": \"$(json_escape "$API_PROXY_URL")\","
    echo "  \"third_party_keys_in_client\": $([ -n "$API_PROXY_URL" ] && echo false || echo true),"
    echo "  \"elsewhere\": {"
    echo "    \"default_region\": \"$ELSEWHERE_DEFAULT_REGION\","
    echo "    \"ui_language\": \"$ELSEWHERE_UI_LANGUAGE\","
    echo "    \"default_providers\": $ELSEWHERE_DEFAULT_PROVIDERS_JS,"
    echo "    \"ignore_providers\": $ELSEWHERE_IGNORE_PROVIDERS_JS,"
    echo "    \"cors_proxy_configured\": $([ -n "$ELSEWHERE_CORS_PROXY_URL" ] && echo true || echo false)"
    echo "  },"
    echo "  \"reviews\": {"
    echo "    \"primary_language\": \"$REVIEWS_PRIMARY_LANGUAGE\","
    echo "    \"secondary_language\": \"$REVIEWS_SECONDARY_LANGUAGE\","
    echo "    \"max_reviews\": $REVIEWS_MAX_REVIEWS,"
    echo "    \"review_preview_length\": $REVIEWS_PREVIEW_LENGTH,"
    echo "    \"expanded_by_default\": $REVIEWS_EXPANDED_BY_DEFAULT,"
    echo "    \"show_language_flags\": $REVIEWS_SHOW_LANGUAGE_FLAGS"
    echo "  },"
    echo "  \"spotlight\": {"
    echo "    \"limit\": $SPOTLIGHT_LIMIT,"
    echo "    \"autoplay_interval_ms\": $SPOTLIGHT_AUTOPLAY_INTERVAL,"
    echo "    \"enable_video_backdrop\": $SPOTLIGHT_ENABLE_VIDEO_BACKDROP,"
    echo "    \"enable_mobile_video\": $SPOTLIGHT_ENABLE_MOBILE_VIDEO,"
    echo "    \"preferred_video_quality\": \"$SPOTLIGHT_PREFERRED_VIDEO_QUALITY\","
    echo "    \"enable_sponsor_block\": $SPOTLIGHT_ENABLE_SPONSOR_BLOCK,"
    echo "    \"cache_ttl_hours\": $SPOTLIGHT_CACHE_TTL_HOURS,"
    echo "    \"cors_proxy_configured\": $([ -n "$SPOTLIGHT_CORS_PROXY_URL" ] && echo true || echo false)"
    echo "  },"
    echo "  \"ratings\": {"
    echo "    \"cache_ttl_hours\": $RATINGS_CACHE_TTL_HOURS,"
    echo "    \"cors_proxy_configured\": $([ -n "$RATINGS_CORS_PROXY_URL" ] && echo true || echo false)"
    echo "  },"
    echo "  \"files\": ["
    for i in "${!JS_NAMES[@]}"; do
        sep=","
        [ "$i" -eq $((${#JS_NAMES[@]} - 1)) ] && sep=""
        echo "    \"$(json_escape "${JS_NAMES[$i]}")\"$sep"
    done
    echo "  ],"
    echo "  \"edited_files\": ["
    for i in "${!EDITED_JS[@]}"; do
        sep=","
        [ "$i" -eq $((${#EDITED_JS[@]} - 1)) ] && sep=""
        echo "    \"$(json_escape "${EDITED_JS[$i]}")\"$sep"
    done
    echo "  ],"
    echo "  \"rollback_script\": \"$(json_escape "$ROLLBACK_FILE")\","
    echo "  \"reapply_script\": \"$(json_escape "$REAPPLY_FILE")\","
    echo "  \"hashes_file\": \"$(json_escape "$HASHES_FILE")\","
    echo "  \"installed_hashes_file\": \"$(json_escape "$INSTALLED_HASHES")\","
    echo "  \"translation_report\": \"$(json_escape "$TRANSLATION_REPORT")\","
    echo "  \"note\": \"API keys are intentionally never written to this file.\""
    echo "}"
} > "$MANIFEST_FILE"

if [ "$HAS_JQ" = "1" ]; then
    jq . "$MANIFEST_FILE" >/dev/null 2>&1 \
        || warn "manifest-$TIMESTAMP.json did not parse cleanly with jq; review it manually."
fi
ok "$MANIFEST_FILE"

{
    echo "{"
    echo "  \"container\": \"$(json_escape "$CONTAINER")\","
    echo "  \"emby_url\": \"$(json_escape "$EMBY_URL")\","
    echo "  \"base\": \"$(json_escape "$BASE")\","
    echo "  \"css_url\": \"$(json_escape "$CSS_URL")\","
    echo "  \"css_pin_ref\": \"$(json_escape "$CSS_PIN_REF")\","
    echo "  \"theme_mode\": \"$(json_escape "$THEME_MODE")\","
    echo "  \"theme_default_for_all_users\": $([ "$THEME_MODE" = "theme" ] && [ "$THEME_SET_AS_DEFAULT" = "1" ] && echo true || echo false),"
    echo "  \"elsewhere\": {"
    echo "    \"default_region\": \"$ELSEWHERE_DEFAULT_REGION\","
    echo "    \"ui_language\": \"$ELSEWHERE_UI_LANGUAGE\","
    echo "    \"default_providers\": $ELSEWHERE_DEFAULT_PROVIDERS_JS,"
    echo "    \"ignore_providers\": $ELSEWHERE_IGNORE_PROVIDERS_JS"
    echo "  },"
    echo "  \"reviews\": {"
    echo "    \"primary_language\": \"$REVIEWS_PRIMARY_LANGUAGE\","
    echo "    \"secondary_language\": \"$REVIEWS_SECONDARY_LANGUAGE\","
    echo "    \"max_reviews\": $REVIEWS_MAX_REVIEWS,"
    echo "    \"review_preview_length\": $REVIEWS_PREVIEW_LENGTH,"
    echo "    \"expanded_by_default\": $REVIEWS_EXPANDED_BY_DEFAULT,"
    echo "    \"show_language_flags\": $REVIEWS_SHOW_LANGUAGE_FLAGS"
    echo "  },"
    echo "  \"spotlight\": {"
    echo "    \"limit\": $SPOTLIGHT_LIMIT,"
    echo "    \"autoplay_interval_ms\": $SPOTLIGHT_AUTOPLAY_INTERVAL,"
    echo "    \"enable_video_backdrop\": $SPOTLIGHT_ENABLE_VIDEO_BACKDROP,"
    echo "    \"enable_mobile_video\": $SPOTLIGHT_ENABLE_MOBILE_VIDEO,"
    echo "    \"preferred_video_quality\": \"$SPOTLIGHT_PREFERRED_VIDEO_QUALITY\","
    echo "    \"enable_sponsor_block\": $SPOTLIGHT_ENABLE_SPONSOR_BLOCK,"
    echo "    \"cache_ttl_hours\": $SPOTLIGHT_CACHE_TTL_HOURS"
    echo "  },"
    echo "  \"ratings\": {"
    echo "    \"cache_ttl_hours\": $RATINGS_CACHE_TTL_HOURS"
    echo "  },"
    echo "  \"last_install_timestamp\": \"$(json_escape "$TIMESTAMP")\""
    echo "}"
} > "$CONFIG_JSON"
chmod 644 "$CONFIG_JSON"
ok "$CONFIG_JSON (no keys, reusable)"

echo >> "$HASHES_FILE"
echo "# SHA256 of files installed in the container ($TIMESTAMP)" >> "$HASHES_FILE"
cat "$INSTALLED_HASHES" >> "$HASHES_FILE"

step "Applying artifact retention (last $BACKUP_RETENTION_COUNT installs)"

prune_old_artifacts() {
    local count
    count="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

    if [ "$count" -le "$BACKUP_RETENTION_COUNT" ]; then
        ok "$count install(s) in $BACKUP_ROOT (limit $BACKUP_RETENTION_COUNT); nothing to prune."
        return 0
    fi

    local to_delete dir ts
    to_delete="$(
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
            | sort | head -n "$((count - BACKUP_RETENTION_COUNT))"
    )"

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        ts="$(basename "$dir")"
        rm -rf "$dir"
        rm -f \
            "$CUSTOM_ROOT/install-$ts.log" \
            "$CUSTOM_ROOT/manifest-$ts.json" \
            "$CUSTOM_ROOT/SHA256SUMS-$ts.txt" \
            "$CUSTOM_ROOT/translation-$ts.txt" \
            "$CUSTOM_ROOT/rollback-$ts.sh" \
            "$CUSTOM_ROOT/reapply-$ts.sh" \
            "$SCRIPT_DIR/emby-backup-$ts.tgz"
        ok "Retention: removed install $ts (backup + correlated artifacts, including the portable .tgz)."
    done <<< "$to_delete"
}

prune_old_artifacts

# ==============================================================================
# 18. FINAL SUMMARY
# ==============================================================================

section "INSTALL COMPLETED"

echo "Container:        $CONTAINER ($CONTAINER_IMAGE)"
if [ "$THEME_MODE" = "theme" ]; then
    if [ "$THEME_SET_AS_DEFAULT" = "1" ]; then
        echo "Theme:            '$THEME_NAME' added to the Theme dropdown and set as the DEFAULT theme (anyone who picked another one manually keeps it); Settings theme untouched"
    else
        echo "Theme:            '$THEME_NAME' added to the Theme dropdown (--no-default-theme: Dark remains the default); Settings theme untouched"
    fi
    echo "Custom CSS:       $CSS_STATUS_TEXT"
else
    echo "Theme:            NOT registered (fallback to CustomCss: $THEME_FALLBACK_REASON)"
    echo "Custom CSS:       $CSS_STATUS_TEXT"
fi
echo "Backup:           $BACKUP_DIR"
echo "Portable backup:  $BACKUP_TGZ"
echo "Manifest:         $MANIFEST_FILE"
echo "Reusable config:  $CONFIG_JSON"
echo "SHA256:           $HASHES_FILE"
echo "Log:              $LOG_FILE"
echo "Translation:      $TRANSLATION_REPORT"
echo "Manual rollback:  $ROLLBACK_FILE"
echo "Reapply:          $REAPPLY_FILE"
echo
echo "Reviews.js:       PRIMARY_LANGUAGE=$REVIEWS_PRIMARY_LANGUAGE, MAX_REVIEWS=$REVIEWS_MAX_REVIEWS"
echo "Spotlight.js:     enableMobileVideo=$SPOTLIGHT_ENABLE_MOBILE_VIDEO, quality=$SPOTLIGHT_PREFERRED_VIDEO_QUALITY, sponsorBlock=$SPOTLIGHT_ENABLE_SPONSOR_BLOCK"
echo "Elsewhere.js:     UI language=$ELSEWHERE_UI_LANGUAGE (see $TRANSLATION_REPORT), region=$ELSEWHERE_DEFAULT_REGION"
echo "                  DEFAULT_PROVIDERS=$ELSEWHERE_DEFAULT_PROVIDERS_JS, IGNORE_PROVIDERS=$ELSEWHERE_IGNORE_PROVIDERS_JS"
echo "CORS proxy:       ${CORS_PROXY_URL:-(empty)}"
if [ -n "$API_PROXY_URL" ]; then
    echo "API proxy:        $API_PROXY_URL (TMDB/MDBList/Kinopoisk keys only in nginx; responses cached for everyone)"
else
    echo "API proxy:        (empty) -- TMDB/MDBList/Kinopoisk keys are embedded in the JS files"
fi
echo
echo "Next steps:"
echo "  1. Open Emby in the browser: $EMBY_URL"
echo "  2. Force a hard reload: Ctrl+Shift+R"
if [ "$THEME_MODE" = "theme" ]; then
    if [ "$THEME_SET_AS_DEFAULT" = "1" ]; then
        echo "  3. '$THEME_NAME' is already the default theme: nothing to pick."
        echo "     Anyone who picked another theme manually (Preferences -> Display ->"
        echo "     Theme, stored in the browser) can switch to '$THEME_NAME' there."
    else
        echo "  3. Preferences -> Display -> Theme: pick '$THEME_NAME' (per user and"
        echo "     per device: Emby stores that choice in the browser)."
    fi
    echo "     Leave 'Settings theme' as it is: the admin panel is no longer"
    echo "     touched by the CSS."
    echo "  4. Check that reviews show up in $REVIEWS_PRIMARY_LANGUAGE (Reviews.js)."
else
    echo "  3. Check that reviews show up in $REVIEWS_PRIMARY_LANGUAGE (Reviews.js)."
fi
echo
echo "If something does not look right:"
echo "  Rollback:  bash '$ROLLBACK_FILE'"
echo "  Reapply:   bash '$REAPPLY_FILE'"
echo

section "NOTES"

echo "API_PROXY_URL:"
if [ -n "$API_PROXY_URL" ]; then
    echo "  The addons' calls to TMDB, MDBList and Kinopoisk go through"
    echo "  $API_PROXY_URL (nginx adds the keys and caches the responses"
    echo "  for all users). The installed JS files only contain a placeholder,"
    echo "  never a real key (verified before installing)."
else
    echo "  Empty: the addons call the APIs directly from the browser with the"
    echo "  keys embedded in the JS files (upstream behavior)."
fi
echo
echo "CORS_PROXY_URL:"
if [ -n "$CORS_PROXY_URL" ]; then
    echo "  Configured in Spotlight.js, emby-ratings.js and emby-elsewhere.js:"
    echo "  $CORS_PROXY_URL"
    echo "  Enables the Rotten Tomatoes/Allocine scraping fallback and the"
    echo "  'where to watch' deep links of Elsewhere. The proxy has an allowlist"
    echo "  of destinations (see deploy/nginx/etc/nginx/snippets/emby-cors-proxy.conf);"
    echo "  if the proxy does not"
    echo "  respond, the addons keep working without those two improvements."
else
    echo "  Empty (on purpose). It enables Elsewhere deep links and the Rotten"
    echo "  Tomatoes/Allocine scraping fallback for old titles; it is forced"
    echo "  to empty in the 3 addons. They work the same, just without those"
    echo "  two specific improvements."
fi
echo
echo "Addon verification (--require-known-hashes):"
echo "  The hash of each addon downloaded today was stored as the new"
echo "  baseline in known-source-sha256sums.txt. If upstream changes an"
echo "  addon in the future, the next run only warns by default --"
echo "  pass --require-known-hashes if you prefer it to abort instead of"
echo "  installing an unreviewed change."
echo

# Closing the exit-code contract: this point is reached only if the install
# finished (with or without CSS degradation), never after a critical
# failure -- those already exited through die_precheck/die_critical/
# on_error/on_interrupt with EXIT_FAILED above. INSTALL_RESULT was already
# fixed when the manifest was generated, a few phases back.
if [ "$INSTALL_RESULT" = "DEGRADED" ]; then
    section "RESULT: DEGRADED (exit $EXIT_DEGRADED)"
    echo "The JS addons install finished correctly, but the CustomCss"
    echo "could not be installed (see above). Non-critical, but it"
    echo "needs attention -- retry the install or the CSS step."
    exit "$EXIT_DEGRADED"
else
    ok "RESULT: SUCCESS (exit $EXIT_OK)"
    exit "$EXIT_OK"
fi
