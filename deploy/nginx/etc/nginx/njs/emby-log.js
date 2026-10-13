// emby-log.js  (njs, http context via js_import)
//
// Pseudonymization of the Emby session token for the access logs:
// instead of storing the real token (a reusable credential) or deleting it
// entirely (correlation is lost), a stable token_id is recorded =
//   HMAC-SHA256(server_secret, token)  -> 16 hex.
// The token_id is the SAME for all requests of a single session (allows
// correlating client -> session -> requests -> playback), is NOT
// reversible to the token, and does NOT work as a credential. The real token is still
// redacted from the URL (see conf.d/emby-log-redaction.conf); this is a separate
// field in the log_format.
//
// Where the token is looked up, in order (first match wins):
//   1. URL query: X-Emby-Token, api_key (web client, HLS/stream URLs)
//   2. Headers:   X-Emby-Token, X-MediaBrowser-Token
//   3. Headers:   Token="..." inside X-Emby-Authorization or Authorization
//                 (Android/TV apps send the token this way, never in the URL)
// The same token yields the same token_id whichever way it was sent.
//
// The secret is read ONCE per worker from a file outside the config
// (chmod 600). If the secret or the token is missing, it returns "-".
import crypto from 'crypto';
import fs from 'fs';

var HMAC_KEY = '';
try {
    HMAC_KEY = fs.readFileSync('/etc/nginx/secrets/emby-token-hmac.key', 'utf8').trim();
} catch (e) {
    HMAC_KEY = '';
}

var AUTH_TOKEN_RE = /Token="([^"]+)"/i;

function findToken(r) {
    var a = r.args || {};
    var t = a['X-Emby-Token'] || a['api_key'];
    if (t) {
        return t;
    }
    var h = r.headersIn;
    t = h['X-Emby-Token'] || h['X-MediaBrowser-Token'];
    if (t) {
        return t;
    }
    var auth = h['X-Emby-Authorization'] || h['Authorization'] || '';
    var m = AUTH_TOKEN_RE.exec(auth);
    return m ? m[1] : '';
}

function tokenId(r) {
    var t = findToken(r);
    if (!t || !HMAC_KEY) {
        return '-';
    }
    return crypto.createHmac('sha256', HMAC_KEY).update(t).digest('hex').substring(0, 16);
}

export default { tokenId };
