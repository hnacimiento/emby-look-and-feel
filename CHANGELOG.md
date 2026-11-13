# Changelog · Registro de cambios

[English](#english) · [Español](#español)

---

## English

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). The script reports its version
with `./install-emby-custom.sh --version`.

### [Unreleased]

### [1.3.1] - 2026-11-13

Tested against Emby 4.10.2.0 (upstream: Embymalism CSS 4.10.2.0 of
2026-10-30; the six addons and `spotlight-items.txt` are unchanged since
1.2.0).

#### Changed
- `TESTED_EMBY_VERSION` is `4.10.2.0`; the compatibility table lists
  4.10.2.0 as current and 4.10.1.0 as earlier. No code changes: the CSS
  auto-match already picks upstream's `main` CSS on Emby 4.10.2.0 and the
  archived `Embymalism_4.10.1.0.css` on 4.10.1.0.

#### Notes
- Upstream's CSS for 4.10.2.0 differs from the archived 4.10.1.0 one only in
  its header. Its only visual change since 1.2.0 (2026-10-15) restyles the
  favorite and played buttons in the season view: blue when active, white
  when not, with a round background on hover.
- Verified on a real upgrade: the watchdog with `--installer` detected
  Emby 4.10.1.0 -> 4.10.2.0 and reinstalled on its own; a second install was
  idempotent and the addons and `theme.css` served through nginx match the
  container byte for byte.

### [1.3.0] - 2026-10-13

#### Added
- Watchdog `--installer PATH`: when the customizations are gone and Emby's
  version changed since the last install (an app update), it runs a full
  `install-emby-custom.sh --silent` instead of only logging that a reinstall
  is needed; with the same version it keeps using reapply.
- The installer's final summary shows how to download and schedule the
  watchdog, with this host's paths.

#### Changed
- README reorganized around what the user gets: product title, "What you
  get", "Quick start" and "After an Emby update" sections, and screenshots
  (before/after GIF, the Theme selector, a title page with the addons).

### [1.2.0] - 2026-10-13

Tested against Emby 4.10.1.0 (upstream: Embymalism CSS 4.10.1.0 and the
rewritten `emby-ratings.js` of 2026-09-30).

#### Added
- `emby-ratings.js` awards via OMDb: optional `OMDB_API_KEY` in
  `secrets/api.env` (wizard, `--silent` environment variable, live check that
  only warns). With the API proxy, `https://www.omdbapi.com/` is rewritten to
  `<API_PROXY_URL>omdb/` and only a placeholder reaches the browser; the new
  nginx `location /api-proxy/omdb/` adds the key, caches answers 7 days (OMDb
  `401` 10 minutes) and answers `503` without calling OMDb when it has no
  key. `render-keys.sh` and `emby-api-keys.conf.example` carry the OMDb key;
  `check.sh` tests the route; the installer smoke-tests it.
- Config keys `RATINGS_ENABLE_AWARDS` and `RATINGS_ENABLE_CUSTOM_RATINGS`
  for the new `enableAwards`/`enableCustomRatings` settings. Settings that
  the downloaded addon does not have are skipped with a warning, so older
  and newer upstream versions keep installing.
- `ratings-data.json` (read by the new `emby-ratings.js` before any API
  call): an empty object is installed by default (no more 404 retries every
  60 s per browser), or your own JSON object with `RATINGS_DATA_FILE`.
  Backed up, restored by rollback, re-copied by reapply, shown by `--status`.
- The CSS follows the Emby version: if upstream `main`'s `Embymalism.css`
  is made for another Emby than the detected one, the archived
  `Archive/Embymalism_<version>.css` for your version is installed instead
  (warning if upstream has none). `CSS_AUTO_MATCH_EMBY_VERSION` (default `1`)
  turns it off; `CSS_PIN_REF` is always respected. The manifest records
  `css_source` and `css_emby_version`.
- Detection and report of the optional NativeSpotlight server plugin used
  by the new `emby-ratings.js` (summary, manifest, `--status`).
- `?v=<sha256 prefix>` on the addon `<script>` tags in `index.html`: a new
  addon version gets a new URL, so neither browsers nor a caching reverse
  proxy keep serving the old file. Verified in PHASE 9/9.
- `purge-assets.sh --all-web` (every cached `/web/` entry).
- When the Emby URL does not answer and the container is on a macvlan/ipvlan
  network (unreachable from its own Docker host), the error explains it and
  suggests a URL through the reverse proxy.
- `--status` also checks `spotlight-items.txt`, `ratings-data.json` and the
  Emby version against the one recorded at install time.

#### Changed
- `TESTED_EMBY_VERSION` is `4.10.1.0`.
- `reapply-<timestamp>.sh` refuses to run (exit `1`, nothing touched) when
  Emby's version differs from the one recorded at install time: its staged
  `index.html`/`skinmanager.js` are the old version's files. `--force`
  overrides. The watchdog logs that case and does not call reapply.
- `purge-assets.sh` prints only the cached URI, never the rest of the cache
  key (which holds the client's Authorization/Cookie values).
- `.gitignore`: the per-site nginx files (`emby-api-keys.conf`,
  `emby-resolver.conf`) are ignored explicitly.

#### Fixed
- `index.html` kept getting a trailing newline Emby's file does not have, so
  every run reported "index.html changed" and rewrote the saved baseline.
- `render-keys.sh --from-truenas` split the keys with `IFS`, so an empty
  optional key would have shifted the next key into the wrong variable; it
  now reads them line by line.
- fail2ban `[emby-api-proxy]` never counted the API proxy's rate-limit `429`:
  `limit_req` answers after the `rewrite`, so the log line carries the
  upstream path (`/3/configuration`) and the filter only matched
  `/api-proxy/...`. A second failregex now matches any `429` with
  `cache_status=-` in the proxy logs (nginx's own answer); a `429` or `401`
  passed through from a third-party API is still not counted.
- API proxy / CORS proxy DNS: the `resolver` moved out of
  `emby-api-common.conf` and `emby-cors-proxy.conf` into a per-site
  `snippets/emby-resolver.conf` (template `emby-resolver.conf.example`, not
  versioned). The hard-coded public resolvers timed out (`could not be
  resolved (110)` → 502) on networks that only allow their own DNS.

#### Security
- Native nginx block of WordPress/PHP vulnerability-scan paths on the Emby
  vhost (`deploy/nginx/etc/nginx/snippets/emby-scan-block.conf`): a regex
  `location` returning `444`, complementing the `[emby-web-scan]` fail2ban
  jail. An OWASP Coraza WAF was evaluated for this and deferred — the
  experimental `coraza-nginx` connector stalls WebSocket/streaming and hangs
  on `deny` (see `docs/SECURITY-LAYERS.md`, layer 11b).
- Access-log `token_id` now also covers tokens sent in headers
  (`X-Emby-Token`, `X-MediaBrowser-Token`, or `Token="…"` inside
  `X-Emby-Authorization` / `Authorization`), not only in the URL. Android/TV
  apps send the token this way, so their sessions were logged as `token_id=-`.

### [1.1.0] - 2026-09-29

#### Added
- API proxy authenticated against the Emby session: nginx reflects the web
  client's `X-Emby-Token` into an `HttpOnly; Secure; SameSite=Strict;
  Path=/api-proxy/` cookie and validates it with `auth_request` against
  `/emby/System/Info` (LAN source IPs bypass); requires
  `--with-http_auth_request_module`. `check.sh --from-wan`, fail2ban filter
  now also counts 401.
- `ELSEWHERE_UI_LANGUAGE` config key (`en` default, `es`, `de`): the
  installer translates emby-elsewhere.js's German UI texts to English or
  Spanish at install time, or leaves them untouched. Recorded in the
  manifest (`elsewhere.ui_language`).
- Spotlight.js's optional `spotlight-items.txt` is now downloaded, staged,
  installed, verified, backed up and re-applied like the addons (a
  comment-only upstream template by default), removing the harmless
  `/web/spotlight-items.txt` 404 out of the box. Recorded in the manifest
  (`spotlight_items_file` / `spotlight_items_sha256`).

#### Changed
- The installer (code, comments, messages, `--help`, generated
  rollback/reapply scripts) is now entirely in English; phase headers are
  `PHASE n/9`. The only Spanish left is the German→Spanish phrase table.
- CI guard no longer hardcodes any deployment value: it fails on private
  addresses outside the documented `192.168.1.x` examples, on any
  `emby.<domain>` other than `emby.example.com`, and on 32-hex tokens.

#### Security
- Found (by comparing a decade-old open-source Emby-for-Samsung client
  against this deployment's real traffic) and fixed an access-log token
  leak: modern Emby clients send the session token as an `X-Emby-Token=`
  URL parameter, not only as a header, so it was being logged in plaintext
  (2,576 occurrences in a single day's log). The token is now redacted from
  the URL and, instead of losing traceability, pseudonymized into a stable
  `token_id = HMAC-SHA256(secret, token)` (njs, `deploy/nginx/etc/nginx/`)
  plus nginx's native `request_id` — session/request correlation with no
  reusable credential in the log. New nginx files
  (`conf.d/emby-log-redaction.conf`, `njs/emby-log.js`, `main.d/njs.conf`)
  ship under `deploy/nginx/`; see
  [docs/SECURITY-LAYERS.md](docs/SECURITY-LAYERS.md) layer 13 for the full
  finding, design, and validation.
- fail2ban `emby-web-scan` jail added (`deploy/nginx/etc/fail2ban/`) that
  bans WordPress/PHP vulnerability scanners hitting the Emby vhost
  (validated 642 matches / 0 false positives).

#### Fixed
- Post-install verification compared Reviews.js against the literals
  `es-AR` / `30` instead of `REVIEWS_PRIMARY_LANGUAGE` / `REVIEWS_MAX_REVIEWS`.

### [1.0.0] - 2026-09-27

First public version.

#### Added
- Installer `install-emby-custom.sh`: auto-detection of the Emby container,
  data path and URL; credentials wizard (`secrets/api.env`, chmod 600);
  download + SHA256 audit of the six upstream addons and Embymalism.css;
  key/setting injection per addon; idempotent `<script>` injection in
  `index.html`; full pre-install backup (+ portable `.tgz`), generated
  `rollback-<ts>.sh` / `reapply-<ts>.sh`; byte-for-byte post-install
  verification; manifest and reusable `config.json`; retention of the last
  5 installs; `--silent`, `--discover-only`, `--require-known-hashes`.
- **Embymalism as an entry of Emby's Theme selector** (patched
  `modules/skinmanager.js` + `modules/themes/embymalism/theme.css`) instead of
  Branding `CustomCss`, so the admin/settings pages (which use Emby's separate
  *Settings theme*) stay untouched. Default main theme for every user unless
  `--no-default-theme` / `THEME_SET_AS_DEFAULT="0"`. Automatic fallback to
  `CustomCss` if a future Emby changes `skinmanager.js`.
- Optional nginx layer (`deploy/nginx/`, mirrors `/etc/nginx/`): allow-listed
  **CORS proxy** for the Rotten Tomatoes / AlloCiné fallback and Elsewhere
  deep links; **API proxy with shared cache** for MDBList/TMDB/Kinopoisk that
  keeps the real API keys server-side (the addons only get a placeholder) and
  serves every user from one cache; fail2ban jail for proxy abuse;
  `check.sh`, `render-keys.sh`, `install.sh` helpers.
- Config file `install-emby-custom.conf` (parsed, validated, never sourced)
  with tracked template `install-emby-custom.conf.example`; `--config=`,
  `--print-config`, `--dry-run`, `--uninstall`, `--version`.
- Test suite (`tests/run_tests.sh`): unit tests for escaping, injection
  helpers, CSS embedding, theme injection, API-proxy rewrite and the config
  loader; integration tests running the real generated rollback/reapply
  scripts against docker/curl stubs. CI workflow (syntax, shellcheck, tests,
  no deployment data in tracked files).

#### Fixed
- False CSS verification mismatch caused by `jq -r` appending a newline
  (now `jq -j`) and by `$(cat)` stripping trailing newlines (now
  `IFS= read -r -d ''`).
- `grep -o | wc -l` counts aborting the run under `pipefail` + `trap ERR`
  when a count is legitimately zero.
- Rollback no longer prints `chmod: No such file` for addons it just removed.

---

## Español

Todos los cambios relevantes del proyecto se documentan acá. El formato
sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); las
versiones siguen [Versionado Semántico](https://semver.org/lang/es/). El
script informa su versión con `./install-emby-custom.sh --version`.

### [Sin publicar]

### [1.3.1] - 2026-11-13

Probado contra Emby 4.10.2.0 (upstream: CSS de Embymalism 4.10.2.0 del
2026-10-30; los seis addons y `spotlight-items.txt` no cambiaron desde
1.2.0).

#### Cambiado
- `TESTED_EMBY_VERSION` es `4.10.2.0`; la tabla de compatibilidad muestra
  4.10.2.0 como actual y 4.10.1.0 como anterior. Sin cambios de código: la
  elección automática del CSS ya toma el `main` de upstream en Emby 4.10.2.0
  y el `Embymalism_4.10.1.0.css` archivado en 4.10.1.0.

#### Notas
- El CSS de upstream para 4.10.2.0 solo difiere del 4.10.1.0 archivado en la
  cabecera. Su único cambio visual desde 1.2.0 (2026-10-15) restiliza los
  botones de favorito y visto en la vista de temporada: azules si están
  activos, blancos si no, con un círculo de fondo al pasar el mouse.
- Verificado en una actualización real: el watchdog con `--installer`
  detectó Emby 4.10.1.0 -> 4.10.2.0 y reinstaló solo; una segunda
  instalación fue idempotente y los addons y el `theme.css` servidos por
  nginx coinciden byte a byte con el contenedor.

### [1.3.0] - 2026-10-13

#### Agregado
- Watchdog `--installer RUTA`: cuando las personalizaciones desaparecieron y
  la versión de Emby cambió desde la última instalación (una actualización de
  la app), corre una instalación completa `install-emby-custom.sh --silent`
  en lugar de solo registrar que hace falta reinstalar; con la misma versión
  sigue usando reapply.
- El resumen final del instalador muestra cómo bajar y programar el watchdog,
  con las rutas de este host.

#### Cambiado
- README reorganizado alrededor de lo que obtiene el usuario: título de
  producto, secciones "Qué obtenés", "Inicio rápido" y "Después de actualizar
  Emby", y capturas (GIF antes/después, el selector de Theme, una ficha con
  los addons).

### [1.2.0] - 2026-10-13

Probado contra Emby 4.10.1.0 (upstream: CSS de Embymalism 4.10.1.0 y el
`emby-ratings.js` reescrito el 2026-09-30).

#### Agregado
- Premios en `emby-ratings.js` vía OMDb: `OMDB_API_KEY` opcional en
  `secrets/api.env` (wizard, variable de entorno en `--silent`, chequeo en
  vivo que solo avisa). Con el API proxy, `https://www.omdbapi.com/` se
  reescribe a `<API_PROXY_URL>omdb/` y al navegador solo llega un
  placeholder; la nueva `location /api-proxy/omdb/` de nginx agrega la key,
  cachea 7 días (el `401` de OMDb, 10 minutos) y responde `503` sin llamar a
  OMDb cuando no tiene key. `render-keys.sh` y `emby-api-keys.conf.example`
  incluyen la key de OMDb; `check.sh` prueba la ruta; el instalador hace un
  smoke test.
- Claves de configuración `RATINGS_ENABLE_AWARDS` y
  `RATINGS_ENABLE_CUSTOM_RATINGS` para los nuevos ajustes
  `enableAwards`/`enableCustomRatings`. Los ajustes que el addon descargado
  no tiene se saltean con un aviso, así que versiones de upstream más viejas
  o más nuevas se siguen instalando.
- `ratings-data.json` (lo lee el nuevo `emby-ratings.js` antes de llamar a
  cualquier API): por defecto se instala un objeto vacío (se acaban los
  reintentos con 404 cada 60 s por navegador), o tu propio objeto JSON con
  `RATINGS_DATA_FILE`. Con backup, restaurado por rollback, re-copiado por
  reapply y mostrado por `--status`.
- El CSS sigue a la versión de Emby: si el `Embymalism.css` de `main` es
  para otro Emby que el detectado, se instala el archivado
  `Archive/Embymalism_<versión>.css` de tu versión (con aviso si upstream no
  tiene uno). `CSS_AUTO_MATCH_EMBY_VERSION` (por defecto `1`) lo desactiva;
  `CSS_PIN_REF` siempre se respeta. El manifest registra `css_source` y
  `css_emby_version`.
- Detección e informe del plugin de servidor opcional NativeSpotlight que
  usa el nuevo `emby-ratings.js` (resumen, manifest, `--status`).
- `?v=<prefijo del sha256>` en los `<script>` de los addons en
  `index.html`: una versión nueva de un addon tiene una URL nueva, así que ni
  los navegadores ni un reverse proxy con caché siguen sirviendo el archivo
  viejo. Verificado en PHASE 9/9.
- `purge-assets.sh --all-web` (todas las entradas cacheadas de `/web/`).
- Cuando la URL de Emby no responde y el container está en una red
  macvlan/ipvlan (inalcanzable desde su propio host Docker), el error lo
  explica y sugiere una URL a través del reverse proxy.
- `--status` también controla `spotlight-items.txt`, `ratings-data.json` y la
  versión de Emby contra la registrada al instalar.

#### Cambiado
- `TESTED_EMBY_VERSION` es `4.10.1.0`.
- `reapply-<timestamp>.sh` se niega a correr (exit `1`, sin tocar nada)
  cuando la versión de Emby difiere de la registrada al instalar: su
  `index.html`/`skinmanager.js` preparados son los archivos de la versión
  vieja. `--force` lo fuerza. El watchdog registra ese caso y no llama a
  reapply.
- `purge-assets.sh` imprime solo la URI cacheada, nunca el resto de la
  clave de caché (que contiene los valores de Authorization/Cookie del
  cliente).
- `.gitignore`: se ignoran explícitamente los archivos nginx por sitio
  (`emby-api-keys.conf`, `emby-resolver.conf`).

#### Corregido
- `index.html` quedaba con un salto de línea final que el archivo de Emby no
  tiene, así que cada corrida informaba "index.html cambió" y reescribía el
  baseline guardado.
- `render-keys.sh --from-truenas` separaba las keys con `IFS`, así que una
  key opcional vacía habría corrido la siguiente a la variable equivocada;
  ahora las lee línea por línea.
- La jail de fail2ban `[emby-api-proxy]` nunca contaba el `429` del rate
  limit del API proxy: `limit_req` responde después del `rewrite`, así que la
  línea del log lleva la ruta del upstream (`/3/configuration`) y el filtro
  solo reconocía `/api-proxy/...`. Una segunda failregex cuenta ahora
  cualquier `429` con `cache_status=-` en los logs del proxy (respuesta del
  propio nginx); un `429` o `401` que viene de una API de terceros sigue sin
  contar.
- DNS del API proxy / CORS proxy: el `resolver` salió de
  `emby-api-common.conf` y `emby-cors-proxy.conf` a un
  `snippets/emby-resolver.conf` por sitio (plantilla
  `emby-resolver.conf.example`, no versionado). Los resolvers públicos fijos
  daban timeout (`could not be resolved (110)` → 502) en redes que solo
  permiten su propio DNS.

#### Seguridad
- Bloqueo nativo de nginx de rutas de escaneo WordPress/PHP en el vhost de
  Emby (`deploy/nginx/etc/nginx/snippets/emby-scan-block.conf`): un `location`
  regex que devuelve `444`, complementando la jail de fail2ban
  `[emby-web-scan]`. Se evaluó un WAF OWASP Coraza para esto y se pospuso — el
  connector experimental `coraza-nginx` cuelga WebSocket/streaming y traba en
  `deny` (ver `docs/SECURITY-LAYERS.md`, capa 11b).
- El `token_id` del log de acceso ahora también cubre tokens enviados en
  headers (`X-Emby-Token`, `X-MediaBrowser-Token`, o `Token="…"` dentro de
  `X-Emby-Authorization` / `Authorization`), no solo en la URL. Las apps de
  Android/TV mandan el token así, y sus sesiones quedaban como `token_id=-`.

### [1.1.0] - 2026-09-29

#### Agregado
- API proxy autenticado contra la sesión de Emby: nginx refleja el
  `X-Emby-Token` de la web en una cookie `HttpOnly; Secure; SameSite=Strict;
  Path=/api-proxy/` y la valida con `auth_request` contra
  `/emby/System/Info` (las IPs de origen de la LAN lo saltean); requiere
  `--with-http_auth_request_module`. `check.sh --from-wan`; el filtro de
  fail2ban ahora también cuenta los 401.
- Clave de configuración `ELSEWHERE_UI_LANGUAGE` (`en` por defecto, `es`,
  `de`): el instalador traduce los textos en alemán de emby-elsewhere.js al
  inglés o al español en el momento de instalar, o los deja intactos. Queda
  registrado en el manifest (`elsewhere.ui_language`).
- El `spotlight-items.txt` opcional de Spotlight.js ahora se descarga,
  stagea, instala, verifica, respalda y re-aplica como los addons (por
  defecto, la plantilla solo-comentarios de upstream), eliminando de fábrica
  el 404 inofensivo de `/web/spotlight-items.txt`. Queda registrado en el
  manifest (`spotlight_items_file` / `spotlight_items_sha256`).

#### Cambiado
- El instalador (código, comentarios, mensajes, `--help`, scripts de
  rollback/reapply generados) está ahora íntegramente en inglés; los
  encabezados de fase son `PHASE n/9`. El único español que queda es la
  tabla de frases alemán→español.
- El guard de CI ya no hardcodea ningún valor del despliegue: falla ante
  direcciones privadas fuera de los ejemplos `192.168.1.x`, ante cualquier
  `emby.<dominio>` que no sea `emby.example.com` y ante tokens de 32 hex.

#### Seguridad
- Encontrado (comparando un cliente open source de Emby para Samsung de hace
  una década contra el tráfico real de este despliegue) y corregido un leak
  del token en el log de acceso: los clientes modernos de Emby mandan el
  token de sesión como parámetro de URL `X-Emby-Token=`, no solo por header,
  así que quedaba en texto plano (2.576 apariciones en un día). Ahora el
  token se redacta de la URL y, en vez de perder trazabilidad, se
  pseudonimiza en un `token_id = HMAC-SHA256(secret, token)` estable (njs,
  `deploy/nginx/etc/nginx/`) más el `request_id` nativo de nginx —
  correlación de sesión/request sin credencial reutilizable en el log. Los
  archivos nuevos (`conf.d/emby-log-redaction.conf`, `njs/emby-log.js`,
  `main.d/njs.conf`) están en `deploy/nginx/`; ver
  [docs/SECURITY-LAYERS.md](docs/SECURITY-LAYERS.md) capa 13 para el hallazgo,
  el diseño y la validación.
- Jail de fail2ban `emby-web-scan` (`deploy/nginx/etc/fail2ban/`) que banea
  escáneres de vulnerabilidades WordPress/PHP contra el vhost de Emby
  (validado 642 matches / 0 falsos positivos).

#### Corregido
- La verificación post-instalación comparaba Reviews.js contra los
  literales `es-AR` / `30` en vez de `REVIEWS_PRIMARY_LANGUAGE` /
  `REVIEWS_MAX_REVIEWS`.

### [1.0.0] - 2026-09-27

Primera versión pública.

#### Agregado
- Instalador `install-emby-custom.sh`: autodetección del container de Emby,
  de su ruta de datos y de su URL; wizard de credenciales
  (`secrets/api.env`, chmod 600); descarga + auditoría SHA256 de los seis
  addons de upstream y de Embymalism.css; inyección de keys/ajustes por
  addon; inyección idempotente de `<script>` en `index.html`; backup
  completo previo (+ `.tgz` portátil), `rollback-<ts>.sh` /
  `reapply-<ts>.sh` generados; verificación byte a byte post-instalación;
  manifest y `config.json` reutilizable; retención de las últimas 5
  instalaciones; `--silent`, `--discover-only`, `--require-known-hashes`.
- **Embymalism como entrada del combo Theme de Emby** (`modules/skinmanager.js`
  parcheado + `modules/themes/embymalism/theme.css`) en vez de `CustomCss`
  de Branding, para que el panel de administración/configuración (que usa
  el *Settings theme* aparte de Emby) quede intacto. Tema principal por
  defecto para todos salvo `--no-default-theme` / `THEME_SET_AS_DEFAULT="0"`.
  Fallback automático a `CustomCss` si un Emby futuro cambia `skinmanager.js`.
- Capa nginx opcional (`deploy/nginx/`, espeja `/etc/nginx/`): **CORS proxy**
  con lista blanca para el fallback de Rotten Tomatoes / AlloCiné y los
  deep-links de Elsewhere; **API proxy con caché compartida** para
  MDBList/TMDB/Kinopoisk que deja las keys reales del lado servidor (los
  addons solo reciben un placeholder) y sirve a todos los usuarios desde
  una sola caché; jail de fail2ban contra abuso del proxy; helpers
  `check.sh`, `render-keys.sh`, `install.sh`.
- Archivo de configuración `install-emby-custom.conf` (parseado, validado,
  nunca "sourceado") con plantilla versionada
  `install-emby-custom.conf.example`; `--config=`, `--print-config`,
  `--dry-run`, `--uninstall`, `--version`.
- Suite de tests (`tests/run_tests.sh`): unitarios de escaping, helpers de
  inyección, embebido de CSS, inyección del tema, reescritura del API proxy
  y cargador de config; de integración corriendo los scripts reales de
  rollback/reapply contra stubs de docker/curl. Workflow de CI (sintaxis,
  shellcheck, tests, sin datos de despliegue en archivos versionados).

#### Corregido
- Falso mismatch en la verificación del CSS por el salto de línea que
  agrega `jq -r` (ahora `jq -j`) y por `$(cat)` que recorta saltos finales
  (ahora `IFS= read -r -d ''`).
- Conteos `grep -o | wc -l` que abortaban la corrida con `pipefail` +
  `trap ERR` cuando el conteo era legítimamente cero.
- El rollback ya no imprime `chmod: No such file` para addons que acaba de
  eliminar.
