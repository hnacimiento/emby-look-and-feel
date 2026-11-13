# Security layers, in request order · Capas de seguridad, en el orden del flujo

[English](#english) · [Español](#español) · Summary: [../SECURITY.md](../SECURITY.md)

---

## English

This walks the path of one request from a browser to the third-party rating
APIs and back, naming every layer it crosses, what that layer stops, and
the recommended setting. Layers marked *(vhost)* are part of the Emby
reverse-proxy vhost the installer assumes exists; layers marked *(this
project)* ship in `deploy/nginx/`; *(host)* are host services.

```
browser ──TLS──> nginx vhost ──> [host check] ──> [location match]
                                                     │
              /emby/…, /web/…  ── admin paths LAN-only ── method gate (WAN) ── Emby
              /api-proxy/…     ── client-origin gate ── rate limit ── key injection ── cache ── TMDB/MDBList/Kinopoisk/OMDb
              /cors-proxy/…    ── target allow-list ── method gate ── cache ── RT/AlloCiné web (opt-in)
                                                     │
                       fail2ban (reads the access logs of the three paths above)
```

### 1. Transport *(vhost)*
TLS with Let's Encrypt, HTTP→HTTPS 301, HTTP/2 + HTTP/3, OCSP stapling,
HSTS (`max-age` rolled out gradually), `X-Content-Type-Options`,
`Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy`.
Stops: passive interception, protocol downgrade. Note: a location that sets
its own `add_header` does not inherit these; the project's snippets set
their own `nosniff`/`Referrer-Policy` for that reason.

### 2. Host check *(vhost)*
`if ($host != "emby.example.com") { return 444; }` — requests for any other
name on this IP are dropped without a response. Stops: IP-scanning bots.

### 3. Admin surface *(vhost)*
`/swagger`, `/emby/System/Configuration|Logs|Restart`, `/emby/ScheduledTasks`,
`/emby/Plugins`, `/emby/Library/Refresh`, activity log: `allow <LAN>; deny all;`
→ a real `403` from WAN (so fail2ban can see it). Stops: remote
administration of the server through the public name.

### 4. Method gate on the app path *(vhost)*
Non-LAN clients may only use GET/HEAD/POST/OPTIONS on `/`. Login
(`/emby/Users/AuthenticateByName`) is rate-limited to 5 POST/min per IP
(`429`). Stops: credential stuffing at speed; odd verbs from scanners.

### 5. Emby's own authentication *(Emby)*
Every `/emby/` API call carries `X-Emby-Token`, validated by Emby. The
installer never weakens this: `EMBY_API_KEY` is only used server-side by
the installer, via a `curl -K` config file, never on a command line.

### 6. API proxy — client-origin gate *(this project)*
`/api-proxy/*` answers only if `Referer`/`Origin` is the vhost's own origin
(PCRE back-reference against `$scheme://$host`, no hostname hardcoded) or a
private-range `http://` origin (Emby opened by LAN IP). Otherwise `403`.
**Strength: soft** — both headers are client-controlled; it is the cheap
first filter and feeds layer 11. Real authentication is layer 6b.

### 6b. API proxy — Emby session (`auth_request`) *(this project)*
Emby's web sends its access token as `X-Emby-Token` on every `/emby/`
call; nginx reflects that token, on 2xx responses only, into a cookie
`emby_proxy_token` (`Path=/api-proxy/; Secure; HttpOnly; SameSite=Strict;
Max-Age=30d` — no JS can read it, it only travels to `/api-proxy/`, another
site cannot make the browser send it). Every `/api-proxy/*` request then
runs `auth_request /_emby_auth`: a LAN source IP passes (Emby opened by IP
has no cookie for the domain, and is already inside the house); otherwise
the cookie is validated against Emby with `GET /emby/System/Info` (200 =
valid session, 401 = refused), result cached 5 min per token. Logging out
or removing the device in Emby invalidates the token and therefore the
proxy. Needs nginx built with `--with-http_auth_request_module`. Kill
switch: comment the `auth_request` line in `emby-api-common.conf`. Stops:
anyone without a live Emby session using the proxy, even with a forged
Referer.

### 7. API proxy — rate limit and method gate *(this project)*
`limit_req` 2 r/s per IP, burst 20 → `429`; only GET/HEAD (`405`);
`OPTIONS` answered locally (`204`). Stops: bulk scraping through the proxy,
which would burn the daily quota of the MDBList key.

### 8. API proxy — key injection and one fixed upstream per location *(this project)*
The addons are installed with a placeholder instead of the real keys; nginx
strips `api_key=`/`apikey=` from the query and adds the real value (query
for TMDB/MDBList/OMDb, `X-API-KEY` header for Kinopoisk) from
`snippets/emby-api-keys.conf` (`chmod 600`, read by the master as root).
Each location proxies to exactly one host — it is not an open proxy. The
installer refuses to install if a real key value is found in a staged
addon. Stops: key exfiltration from the client, key sharing between users.

### 9. Shared cache *(this project)*
`proxy_cache` keyed by provider + path + query-without-key; `24h`/`7d`
TTLs; stale entries served instantly while refreshed in the background.
Besides speed, it caps how much traffic any one client can generate toward
the third-party API (a repeated request never leaves nginx). Recommended:
keep `inactive`/`max_size` bounded (30d / 512 MB); watch hit ratio with
`deploy/nginx/check.sh`.

### 10. CORS proxy — target allow-list *(this project)*
`/cors-proxy/<url>` forwards only to `rottentomatoes.com` and `allocine.fr`
(`403` otherwise; TMDB's website is excluded on purpose), GET/HEAD only, cookies stripped both
ways, target CSP/frame headers removed, redirects rewritten back through
the proxy (and therefore through the allow-list again). Stops: SSRF-style
use of the proxy to reach arbitrary hosts, cookie leakage.

### 11. fail2ban *(host)*
Jails read nginx's access logs: `[emby]` (Emby app-level auth failures),
`[emby-admin-probe]` (403 on the admin paths), and this project's
`[emby-api-proxy]` (401/403/405/429 on `/api-proxy/` and `/cors-proxy/`, including the
rate-limit 429, which nginx logs with the already rewritten upstream path,
`maxretry 10` in `10m`, `bantime 1h`), and `[emby-web-scan]` (WordPress/PHP
vulnerability scanners on the vhost: `/wp-json`, `xmlrpc`, `.env`, …,
`maxretry 2`). Stops: sustained probing/abuse from one IP at the firewall,
before nginx spends more cycles on it. Test a filter with
`fail2ban-regex <log> <filter>` before enabling it.

### 11b. Native scan-path block *(`snippets/emby-scan-block.conf`, shipped here)*
A regex `location` on the Emby vhost drops the same vulnerability-scan paths
with `return 444` (connection closed, no response) *at request time*, before
they reach the app — complementing the after-the-fact `[emby-web-scan]` ban.
It is deliberately a plain `location`, **not** a WAF engine: an OWASP Coraza
WAF was evaluated here and caused an outage (the experimental `coraza-nginx`
connector stalls WebSocket/streaming and hangs on `deny`), so the engine was
deferred.
A `location`/`return` cannot sit on the WebSocket/streaming data path, so it
carries none of that risk.

### 12. Installer-side controls *(this project)*
Downloads hashed and compared with the last good install
(`--require-known-hashes` to hard-stop on change; `CSS_PIN_REF` to pin);
every file verified byte-for-byte in the container; `skinmanager.js`
patched at one unique anchor and verified to differ from Emby's original by
exactly the inserted entry; full backup + rollback before anything is
touched; config file parsed and validated, never sourced; secrets file
ownership/permissions checked; concurrent runs excluded with `flock`.

### 13. Access-log token privacy + traceability *(`conf.d/emby-log-redaction.conf` + `njs/emby-log.js`, shipped here; the nginx host is managed elsewhere)*
Found 2026-09-28 while comparing an old (2015) open-source Samsung Smart TV
Emby client against this deployment's real traffic, as a side project to
understand the protocol better (not a scheduled audit): the old client sent
the session token as the `X-MediaBrowser-Token` **header**; every current
Emby client (Emby Web, Emby for Android, Emby for Samsung/Tizen) instead
sends it as an `X-Emby-Token=<32-hex>` **URL query parameter**. The vhost
already had a redaction map for the `api_key=` URL-parameter fallback,
but its own comment explicitly assumed *"the header form
(X-Emby-Token) is unaffected"* — true for the 2015 protocol, false for every
client in use today. Result: **2,576 unredacted session tokens** in a single
day's `emby_access.log` before the fix (confirmed by grep, not estimated).

Fix (kept OUT of the shared `nginx.conf` by design): a new dedicated file
`conf.d/emby-log-redaction.conf` (http context, shipped in this repo under
`deploy/nginx/etc/nginx/conf.d/`) defines `map $args_safe $emby_args_safe`
that chains on the existing api_key-redacted `$args_safe` and additionally
redacts `X-Emby-Token=<value>`; the Emby `log_format`s (`emby_timing` /
`emby_cache` in `conf.d/emby-tuning.conf`) are pointed at `$emby_args_safe`.
`nginx.conf` is left untouched. Backed up, `nginx -t`, reloaded with zero
downtime.
**Pseudonymization instead of blind redaction (traceability preserved).**
Full redaction removes a credential but also destroys the ability to
correlate a session's requests. So alongside redacting the raw token from the
URL, the Emby `log_format`s now also carry:
- `token_id=$emby_token_id` — a stable `HMAC-SHA256(server_secret, token)`
  truncated to 16 hex, computed at log time by the njs module
  `njs/emby-log.js`. It is the **same** value for every request of one
  session (so cliente → sesión → requests → playback → timestamps can be
  reconstructed) and for token reuse/theft detection (same token_id from two
  IPs/devices), yet it is **not reversible** to the token and is **not a
  usable credential**. The secret lives in `/etc/nginx/secrets/emby-token-hmac.key`
  (chmod 600), read once per worker; rotating it changes all token_ids
  (breaks cross-time correlation — documented, acceptable). The token is
  looked up in the URL first and then in the headers (`X-Emby-Token`,
  `X-MediaBrowser-Token`, `Token="…"` in `X-Emby-Authorization` /
  `Authorization`), so Android/TV apps — which never put it in the URL — get
  a token_id too, and the same token gives the same id either way.
- `request_id=$request_id` — nginx's native per-request unique id, for
  per-request tracing. No module or secret needed.

Together with what the URL already carries unredacted (`X-Emby-Device-Id`,
`X-Emby-Client`, and `UserId` on user-scoped paths, plus `PlaySessionId` on
playback), the log keeps device-, user-, session- and request-level
traceability with **no** plaintext credential.

Enabling njs cost exactly **one** generic line in `nginx.conf`
(`include /etc/nginx/main.d/*.conf;`); `load_module` (main-context only, so it
cannot live in `conf.d/`) sits in `main.d/njs.conf`. That is the only
`nginx.conf` line these improvements need, and it is dynamic-module
infrastructure, not Emby logic.

Verified against **real production traffic** (the household's Samsung TV,
mid-playback) rather than a synthetic request: `X-Emby-Token=REDACTED` and
`api_key=REDACTED` confirmed, `token_id` stable across a session (1 id / 4
requests) while `request_id` was unique per request, zero raw tokens logged
since. Stops: session tokens sitting in plaintext, readable by anything with
read access to the log file (backups, a log-shipper, another service on the
same host), for as long as the log retention window (weeks to months here) —
without losing forensic correlation.

**Known gaps, left as-is on purpose:**
- Logs written *before* the fix (rotated `.gz` files going back to August,
  plus that day's own log before the reload) still hold real tokens in
  plaintext. Purging/rotating them is a retention decision for whoever owns
  that host, not something this project's tooling did unilaterally.
- The nginx host is managed by a separate, Ansible-managed infrastructure
  project. `nginx.conf` is deliberately not modified; the redaction lives in
  `conf.d/emby-log-redaction.conf` (new) plus a two-token change to
  `conf.d/emby-tuning.conf`'s Emby `log_format`s. Those live on the host but
  will be overwritten by that project's next provisioning run unless ported
  into its templates. Documented here because the *finding* came from this project's
  investigation and affects this deployment either way.

---

## Español

Recorre el camino de un pedido desde el navegador hasta las APIs de ratings
de terceros y vuelta, nombrando cada capa que atraviesa, qué frena esa capa
y la configuración recomendada. Las capas marcadas *(vhost)* son parte del
vhost del reverse proxy de Emby que el instalador da por existente; las
marcadas *(este proyecto)* vienen en `deploy/nginx/`; *(host)* son servicios
del host.

```
navegador ──TLS──> vhost nginx ──> [chequeo de host] ──> [match de location]
                                                          │
              /emby/…, /web/…  ── rutas admin solo LAN ── filtro de métodos (WAN) ── Emby
              /api-proxy/…     ── origen del cliente ── rate limit ── inyección de key ── caché ── TMDB/MDBList/Kinopoisk/OMDb
              /cors-proxy/…    ── lista blanca de destinos ── filtro de métodos ── caché ── RT/AlloCiné web (opcional)
                                                          │
                          fail2ban (lee los access logs de las tres rutas de arriba)
```

### 1. Transporte *(vhost)*
TLS con Let's Encrypt, 301 de HTTP a HTTPS, HTTP/2 + HTTP/3, OCSP
stapling, HSTS (`max-age` desplegado gradualmente),
`X-Content-Type-Options`, `Referrer-Policy: strict-origin-when-cross-origin`,
`Permissions-Policy`. Frena: intercepción pasiva, downgrade de protocolo.
Nota: una location que define su propio `add_header` no hereda estos; por
eso los snippets del proyecto ponen sus propios `nosniff`/`Referrer-Policy`.

### 2. Chequeo de host *(vhost)*
`if ($host != "emby.example.com") { return 444; }` — los pedidos a
cualquier otro nombre sobre esta IP se cortan sin respuesta. Frena: bots
que barren IPs.

### 3. Superficie de administración *(vhost)*
`/swagger`, `/emby/System/Configuration|Logs|Restart`, `/emby/ScheduledTasks`,
`/emby/Plugins`, `/emby/Library/Refresh`, activity log: `allow <LAN>; deny all;`
→ un `403` real desde WAN (para que fail2ban lo vea). Frena: administrar el
servidor a través del nombre público.

### 4. Filtro de métodos en la ruta de la app *(vhost)*
Los clientes fuera de la LAN solo pueden usar GET/HEAD/POST/OPTIONS en `/`.
El login (`/emby/Users/AuthenticateByName`) se limita a 5 POST/min por IP
(`429`). Frena: credential stuffing a velocidad; verbos raros de scanners.

### 5. La autenticación propia de Emby *(Emby)*
Cada llamada `/emby/` lleva `X-Emby-Token`, validado por Emby. El instalador
nunca la debilita: `EMBY_API_KEY` solo la usa el instalador del lado
servidor, vía un archivo de config de `curl -K`, nunca en una línea de
comando.

### 6. API proxy — origen del cliente *(este proyecto)*
`/api-proxy/*` responde solo si `Referer`/`Origin` es el origen del propio
vhost (retrorreferencia PCRE contra `$scheme://$host`, sin hostname
hardcodeado) o un origen `http://` de rango privado (Emby abierto por IP de
LAN). Si no, `403`. **Fuerza: blanda** — ambos headers los controla el
cliente; es el primer filtro barato y alimenta la capa 11. La autenticación
real es la capa 6b.

### 6b. API proxy — sesión de Emby (`auth_request`) *(este proyecto)*
La web de Emby manda su token de acceso como `X-Emby-Token` en cada llamada
a `/emby/`; nginx refleja ese token, solo en respuestas 2xx, en una cookie
`emby_proxy_token` (`Path=/api-proxy/; Secure; HttpOnly; SameSite=Strict;
Max-Age=30d` — ningún JS la lee, solo viaja a `/api-proxy/`, otro sitio no
puede hacer que el navegador la mande). Cada pedido a `/api-proxy/*` corre
entonces `auth_request /_emby_auth`: una IP de origen en la LAN pasa (Emby
abierto por IP no tiene la cookie del dominio y ya está dentro de casa); si
no, la cookie se valida contra Emby con `GET /emby/System/Info` (200 =
sesión válida, 401 = rechazada), resultado cacheado 5 min por token.
Cerrar sesión o borrar el dispositivo en Emby invalida el token y por lo
tanto el proxy. Requiere nginx compilado con
`--with-http_auth_request_module`. Kill switch: comentar la línea
`auth_request` en `emby-api-common.conf`. Frena: a cualquiera sin una
sesión viva de Emby, aunque falsifique el Referer.

### 7. API proxy — rate limit y filtro de métodos *(este proyecto)*
`limit_req` 2 r/s por IP, burst 20 → `429`; solo GET/HEAD (`405`); `OPTIONS`
respondido localmente (`204`). Frena: scraping masivo a través del proxy,
que quemaría el cupo diario de la key de MDBList.

### 8. API proxy — inyección de key y un solo destino por location *(este proyecto)*
Los addons se instalan con un placeholder en vez de las keys reales; nginx
quita `api_key=`/`apikey=` del query y agrega el valor real (query para
TMDB/MDBList/OMDb, header `X-API-KEY` para Kinopoisk) desde
`snippets/emby-api-keys.conf` (`chmod 600`, lo lee el master como root).
Cada location proxya exactamente a un host — no es un proxy abierto. El
instalador se niega a instalar si encuentra una key real en un addon
preparado. Frena: exfiltración de keys desde el cliente, keys compartidas
entre usuarios.

### 9. Caché compartida *(este proyecto)*
`proxy_cache` con clave proveedor + ruta + query-sin-key; TTL `24h`/`7d`;
las entradas vencidas se sirven al instante mientras se refrescan en
segundo plano. Además de velocidad, acota cuánto tráfico puede generar un
cliente hacia la API de terceros (un pedido repetido nunca sale de nginx).
Recomendado: `inactive`/`max_size` acotados (30d / 512 MB); mirar el hit
ratio con `deploy/nginx/check.sh`.

### 10. CORS proxy — lista blanca de destinos *(este proyecto)*
`/cors-proxy/<url>` reenvía solo a `rottentomatoes.com` y `allocine.fr`
(`403` si no; el sitio de TMDB queda fuera a propósito), solo GET/HEAD, cookies vaciadas en ambos
sentidos, CSP/frame del destino eliminados, redirects reescritos para volver
a pasar por el proxy (y por la lista blanca). Frena: uso tipo SSRF del proxy
para llegar a hosts arbitrarios, fuga de cookies.

### 11. fail2ban *(host)*
Las jails leen los access logs de nginx: `[emby]` (fallos de auth de la app
Emby), `[emby-admin-probe]` (403 en las rutas admin) y la de este proyecto
`[emby-api-proxy]` (401/403/405/429 en `/api-proxy/` y `/cors-proxy/`, incluido el
429 del rate limit, que nginx registra con la ruta del upstream ya reescrita,
`maxretry 10` en `10m`, `bantime 1h`) y `[emby-web-scan]` (escáneres de
vulnerabilidades WordPress/PHP en el vhost: `/wp-json`, `xmlrpc`, `.env`, …,
`maxretry 2`). Frena: sondeo/abuso sostenido desde una IP, en el firewall,
antes de que nginx gaste más ciclos. Probar un filtro con
`fail2ban-regex <log> <filtro>` antes de habilitarlo.

### 11b. Bloqueo nativo de rutas de escaneo *(`snippets/emby-scan-block.conf`, incluido acá)*
Un `location` regex en el vhost de Emby dropea las mismas rutas de escaneo con
`return 444` (cierra la conexión, sin respuesta) *en tiempo de request*, antes
de que lleguen a la app — complementa el ban a posteriori de `[emby-web-scan]`.
Es a propósito un `location` plano, **no** un motor WAF: se evaluó Coraza (WAF
OWASP) acá y provocó un corte de acceso (el connector experimental
`coraza-nginx` cuelga WebSocket/streaming y traba en `deny`), así que el motor
quedó pospuesto.
Un `location`/`return` no puede sentarse sobre el camino de datos de
WebSocket/streaming, así que no tiene ese riesgo.

### 12. Controles del lado del instalador *(este proyecto)*
Descargas hasheadas y comparadas con la última instalación buena
(`--require-known-hashes` para frenar ante un cambio; `CSS_PIN_REF` para
fijar); cada archivo verificado byte a byte en el container;
`skinmanager.js` parcheado en un único ancla y verificado para que difiera
del original de Emby exactamente en la entrada insertada; backup completo +
rollback antes de tocar nada; archivo de configuración parseado y validado,
nunca "sourceado"; dueño/permisos del archivo de secretos verificados;
corridas concurrentes excluidas con `flock`.

### 13. Privacidad del token + trazabilidad en el log de acceso *(`conf.d/emby-log-redaction.conf` + `njs/emby-log.js`, incluidos acá; el host de nginx se gestiona aparte)*
Encontrado el 2026-09-28 al comparar un cliente viejo (2015), open source, de
Emby para Samsung Smart TV contra el tráfico real de este despliegue, como
proyecto paralelo para entender mejor el protocolo (no una auditoría
agendada): el cliente viejo mandaba el token de sesión por el **header**
`X-MediaBrowser-Token`; todo cliente actual de Emby (Emby Web, Emby for
Android, Emby for Samsung/Tizen) lo manda en cambio como **parámetro de URL**
`X-Emby-Token=<32-hex>`. El vhost ya tenía un `map` de enmascarado para el
fallback por URL `api_key=`, pero su propio comentario
asumía explícitamente *"the header form (X-Emby-Token) is unaffected"*
—cierto para el protocolo de 2015, falso para cualquier cliente de hoy.
Resultado: **2.576 tokens de sesión sin enmascarar** en un solo día de
`emby_access.log` antes del fix (confirmado con grep, no estimado).

Arreglo (dejado FUERA del `nginx.conf` compartido a propósito): un archivo
nuevo `conf.d/emby-log-redaction.conf` (contexto http, incluido en este repo
bajo `deploy/nginx/etc/nginx/conf.d/`) define `map $args_safe $emby_args_safe`
que se encadena sobre el `$args_safe` ya existente (con api_key redactada) y
además enmascara `X-Emby-Token=<valor>`; los `log_format` de Emby
(`emby_timing` / `emby_cache` en `conf.d/emby-tuning.conf`) se apuntan a
`$emby_args_safe`. `nginx.conf` queda intacto. Con backup, `nginx -t`,
recargado sin caída.

**Pseudonimización en vez de redacción a ciegas (trazabilidad preservada).**
Borrar el token del todo quita una credencial pero también destruye la
correlación entre las requests de una sesión. Por eso, además de redactar el
token crudo de la URL, los `log_format` de Emby ahora llevan:
- `token_id=$emby_token_id` — un `HMAC-SHA256(secret_servidor, token)`
  truncado a 16 hex, calculado en tiempo de log por el módulo njs
  `njs/emby-log.js`. Es el **mismo** valor para todas las requests de una
  sesión (permite reconstruir cliente → sesión → requests → reproducción →
  timestamps) y detectar reuso/robo de token (mismo token_id desde dos
  IPs/devices), pero **no es reversible** al token ni sirve como credencial.
  El secreto vive en `/etc/nginx/secrets/emby-token-hmac.key` (chmod 600),
  leído una vez por worker; rotarlo cambia todos los token_ids (rompe la
  correlación histórica — documentado, aceptable). El token se busca primero
  en la URL y después en los headers (`X-Emby-Token`, `X-MediaBrowser-Token`,
  `Token="…"` en `X-Emby-Authorization` / `Authorization`), así las apps de
  Android/TV — que nunca lo ponen en la URL — también tienen token_id, y el
  mismo token da el mismo id por cualquiera de las dos vías.
- `request_id=$request_id` — el id único por request nativo de nginx, para
  trazado por-request. No necesita módulo ni secreto.

Junto con lo que la URL ya lleva sin redactar (`X-Emby-Device-Id`,
`X-Emby-Client`, y `UserId` en rutas por usuario, más `PlaySessionId` en
reproducción), el log mantiene trazabilidad a nivel dispositivo, usuario,
sesión y request **sin** ninguna credencial en texto plano.

Habilitar njs costó exactamente **una** línea genérica en `nginx.conf`
(`include /etc/nginx/main.d/*.conf;`); el `load_module` (solo contexto
principal, no puede ir en `conf.d/`) vive en `main.d/njs.conf`. Es la única
línea de `nginx.conf` que estas mejoras necesitan, y es infraestructura de
carga de módulos, no lógica de Emby.

Verificado contra **tráfico real de producción** (la Smart TV Samsung de la
casa, reproduciendo algo) en vez de un pedido sintético: `X-Emby-Token=REDACTED`
y `api_key=REDACTED` confirmados, `token_id` estable en la sesión (1 id / 4
requests) y `request_id` único por request, cero tokens crudos desde entonces.
Frena: tokens de sesión quedando en texto plano, legibles por cualquier cosa
con acceso de lectura al archivo de log (backups, un log-shipper, otro servicio
en el mismo host), durante toda la ventana de retención — sin perder la
correlación forense.

**Huecos conocidos, dejados a propósito:**
- Los logs escritos *antes* del fix (los `.gz` rotados desde agosto, más lo
  que ese mismo día ya había quedado escrito antes del reload) siguen con
  tokens reales en texto plano. Purgar/rotar esos archivos es una decisión
  de retención de quien administra ese host, no algo que la herramienta de
  este proyecto hizo por su cuenta.
- El host de nginx lo gestiona un proyecto de infraestructura separado
  (Ansible). `nginx.conf` NO se modifica a propósito; la redacción vive en
  `conf.d/emby-log-redaction.conf` (nuevo) más un cambio de dos tokens en los
  `log_format` de Emby de `conf.d/emby-tuning.conf`. Eso quedó en vivo en el
  host, pero la próxima corrida de ese otro proyecto lo va a pisar salvo que se
  porte a sus templates. Se documenta acá porque
  el *hallazgo* salió de la investigación de este proyecto y afecta a este
  despliegue de cualquier manera.
