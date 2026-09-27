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
              /api-proxy/…     ── client-origin gate ── rate limit ── key injection ── cache ── TMDB/MDBList/Kinopoisk
              /cors-proxy/…    ── target allow-list ── method gate ── cache ── RT/AlloCiné/TMDB web
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
for TMDB/MDBList, `X-API-KEY` header for Kinopoisk) from
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
`/cors-proxy/<url>` forwards only to `rottentomatoes.com`, `allocine.fr`,
`themoviedb.org` (`403` otherwise), GET/HEAD only, cookies stripped both
ways, target CSP/frame headers removed, redirects rewritten back through
the proxy (and therefore through the allow-list again). Stops: SSRF-style
use of the proxy to reach arbitrary hosts, cookie leakage.

### 11. fail2ban *(host)*
Jails read nginx's access logs: `[emby]` (Emby app-level auth failures),
`[emby-admin-probe]` (403 on the admin paths), and this project's
`[emby-api-proxy]` (403/405/429 on `/api-proxy/` and `/cors-proxy/`,
`maxretry 10` in `10m`, `bantime 1h`). Stops: sustained probing/abuse from
one IP at the firewall, before nginx spends more cycles on it. Test a
filter with `fail2ban-regex <log> <filter>` before enabling it.

### 12. Installer-side controls *(this project)*
Downloads hashed and compared with the last good install
(`--require-known-hashes` to hard-stop on change; `CSS_PIN_REF` to pin);
every file verified byte-for-byte in the container; `skinmanager.js`
patched at one unique anchor and verified to differ from Emby's original by
exactly the inserted entry; full backup + rollback before anything is
touched; config file parsed and validated, never sourced; secrets file
ownership/permissions checked; concurrent runs excluded with `flock`.

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
              /api-proxy/…     ── origen del cliente ── rate limit ── inyección de key ── caché ── TMDB/MDBList/Kinopoisk
              /cors-proxy/…    ── lista blanca de destinos ── filtro de métodos ── caché ── RT/AlloCiné/TMDB web
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
TMDB/MDBList, header `X-API-KEY` para Kinopoisk) desde
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
`/cors-proxy/<url>` reenvía solo a `rottentomatoes.com`, `allocine.fr`,
`themoviedb.org` (`403` si no), solo GET/HEAD, cookies vaciadas en ambos
sentidos, CSP/frame del destino eliminados, redirects reescritos para volver
a pasar por el proxy (y por la lista blanca). Frena: uso tipo SSRF del proxy
para llegar a hosts arbitrarios, fuga de cookies.

### 11. fail2ban *(host)*
Las jails leen los access logs de nginx: `[emby]` (fallos de auth de la app
Emby), `[emby-admin-probe]` (403 en las rutas admin) y la de este proyecto
`[emby-api-proxy]` (403/405/429 en `/api-proxy/` y `/cors-proxy/`,
`maxretry 10` en `10m`, `bantime 1h`). Frena: sondeo/abuso sostenido desde
una IP, en el firewall, antes de que nginx gaste más ciclos. Probar un
filtro con `fail2ban-regex <log> <filtro>` antes de habilitarlo.

### 12. Controles del lado del instalador *(este proyecto)*
Descargas hasheadas y comparadas con la última instalación buena
(`--require-known-hashes` para frenar ante un cambio; `CSS_PIN_REF` para
fijar); cada archivo verificado byte a byte en el container;
`skinmanager.js` parcheado en un único ancla y verificado para que difiera
del original de Emby exactamente en la entrada insertada; backup completo +
rollback antes de tocar nada; archivo de configuración parseado y validado,
nunca "sourceado"; dueño/permisos del archivo de secretos verificados;
corridas concurrentes excluidas con `flock`.
