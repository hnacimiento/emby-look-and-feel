# Changelog · Registro de cambios

[English](#english) · [Español](#español)

---

## English

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). The script reports its version
with `./install-emby-custom.sh --version`.

### [Unreleased]

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

#### Changed
- The installer (code, comments, messages, `--help`, generated
  rollback/reapply scripts) is now entirely in English; phase headers are
  `PHASE n/9`. The only Spanish left is the German→Spanish phrase table.
- CI guard no longer hardcodes any deployment value: it fails on private
  addresses outside the documented `192.168.1.x` examples, on any
  `emby.<domain>` other than `emby.example.com`, and on 32-hex tokens.

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

#### Cambiado
- El instalador (código, comentarios, mensajes, `--help`, scripts de
  rollback/reapply generados) está ahora íntegramente en inglés; los
  encabezados de fase son `PHASE n/9`. El único español que queda es la
  tabla de frases alemán→español.
- El guard de CI ya no hardcodea ningún valor del despliegue: falla ante
  direcciones privadas fuera de los ejemplos `192.168.1.x`, ante cualquier
  `emby.<dominio>` que no sea `emby.example.com` y ante tokens de 32 hex.

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
