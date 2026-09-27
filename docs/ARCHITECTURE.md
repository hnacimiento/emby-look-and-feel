# Architecture & design rationale · Arquitectura y razones de diseño

**[English](#english) · [Español](#español)**

For whoever **maintains or extends** `install-emby-custom.sh`: *why* things are built the way they are. Usage is in the main [README](../README.md); security layer by layer in [SECURITY-LAYERS.md](SECURITY-LAYERS.md).

Para quien **mantiene o extiende** `install-emby-custom.sh`: *por qué* las cosas están hechas así. El uso está en el [README](../README.md) principal; la seguridad capa por capa en [SECURITY-LAYERS.md](SECURITY-LAYERS.md).

---

# English

## Compatibility and future Emby versions

The script targets one known-good version (`TESTED_EMBY_VERSION`, near the top) and says so rather than guessing at API shapes it has never seen. Every run queries the real server version (`/emby/System/Info/Public`), warns on mismatch (never fails) and records it in the manifest for later correlation. It ships no speculative fallbacks for hypothetical future Branding paths or `dashboard-ui` layouts; instead it keeps the things most likely to change as single named constants (`EMBY_BRANDING_GET_PATH`, `EMBY_BRANDING_POST_PATH`, `DASHBOARD_CONTAINER_DIR`, `SKINMANAGER_REL`, the `THEME_*` anchors, `API_BASE_*`), fails loudly with the exact HTTP status/endpoint when a Branding call misbehaves, and fails loudly naming the missing declaration when an addon's injection point is gone. The one place it degrades instead of failing is the theme registration: if the `skinmanager.js` anchor is not found exactly once, it falls back to Branding `CustomCss` with a warning, because "admin pages look wrong again" is a better outcome after an Emby update than "no theme at all".

## Configuration: script constants vs. config file

Three kinds of values exist. **Technical constants** (paths inside the container, API endpoints, upstream URLs, anchors) are code and stay in the script. **Deployment and product values** (proxy URLs, LAN IP for the smoke test, region, languages, Spotlight/ratings settings, retention, default theme) have built-in defaults in the script that are deliberately generic, and get their real values from `install-emby-custom.conf` (`CONFIG_KEYS` allow-list, `load_config_file`). **Secrets** live only in `secrets/api.env`.

The config file is **parsed, never sourced**: a line must match `KEY=value`, the key must be in `CONFIG_KEYS`, and the value is validated by type (`CONFIG_BOOL_KEYS`, `CONFIG_INT_KEYS`, `CONFIG_URL_SLASH_KEYS`, plus per-key rules for URL shape, IPv4, region code, volume, video quality) and rejected if it contains `$` or backticks. Assignment is `printf -v`, so nothing in the file can execute. List keys arrive as `a|b|c` strings and are split into the arrays the injection helpers expect. Precedence is CLI flag > file > default; the file is loaded once `die_precheck`/`warn` exist (section 4b), and derived values (`CSS_URL`, the per-addon `*_CORS_PROXY_URL`) are computed after it. `--print-config` prints the effective set with `%q` and exits before touching anything. `tests/unit/test_config_file.sh` also validates every key in the tracked `.conf.example` through the real loader, so the template can never document a key the script rejects.

## Addon injection mechanisms

Each addon exposes its configurable values in whatever format its upstream author chose:

| File | Format | Example |
|---|---|---|
| `emby-elsewhere.js`, `Reviews.js` | `const NAME = value;` | `const MAX_REVIEWS = 30;` |
| `Spotlight.js`, `emby-ratings.js` | object property | `TMDB_API_KEY: 'x',` |

Two independent families of `sed`-based helpers handle this. `set_or_die_const_string` / `set_or_inject_const_string` / `set_or_inject_const_raw` / `set_or_inject_const_array_raw` / `set_if_declared_const_string` / `verify_or_warn_const_raw` for the `const` style (some inject a missing declaration, some require it; `set_if_declared_const_string` enforces "never add `TMDB_API_KEY` to `Reviews.js` if it wasn't there"; the array variant needs its own verification because `[`/`]` are ERE metacharacters). `set_or_die_property_string` / `set_or_die_property_raw` for the property style, preserving the original quote character, the trailing comma (present or not) and any inline comment by re-emitting everything after the value unchanged.

Both families require the target to exist exactly once (except where noted) and `die_precheck` naming it otherwise — never a silent skip. Two narrow families are easier to verify than one clever regex that would have to handle both shapes with and without trailing commas/comments. Post-substitution verification is anchored to the declaration itself (`NAME[:=]\s*(['"])value\1` at line start), not a whole-file substring search: a two-letter region or an empty `CORS_PROXY_URL` would otherwise match trivially and mask a `sed` that changed nothing.

`rewrite_api_base` (API-proxy mode) is the third helper: fixed-string count of the base URL, `sed` with escaped pattern and replacement, then it asserts zero originals remain and at least as many rewritten. Its counts use `{ grep -o … || true; } | wc -l` because `grep -o` exits 1 on zero matches, which under `pipefail` + the script's `ERR` trap aborted a real install even though zero remaining originals is the correct result (bash ignores `set -e` inside command substitutions but the trap still fires) — `tests/unit/test_api_proxy_rewrite.sh` reproduces that under `set -E` + `trap ERR`.

### Theme registration in `modules/skinmanager.js`

Embymalism is not installed as Branding `CustomCss` (loaded once, globally, by `app.js` regardless of the active theme) but as an entry in Emby's theme list, so it is active only as a main theme and never on the admin/settings views, which run under the separate *Settings theme*. Mechanics (PHASE 6/9 "Preparación del tema", `theme_*` helpers):

- `AllThemes` in `skinmanager.js` is a hardcoded array literal with no extension point. The file is treated like `index.html`: pull the container's copy, strip our entry if present (`theme_strip_entry`, literal removal of both the entry and the default-theme literal, regardless of the current mode), compare with the persisted baseline `custom/skinmanager.js.original` (refreshed when Emby's copy changed), re-inject from that baseline every run.
- `theme_inject_entry` inserts `THEME_ENTRY` immediately before `THEME_ANCHOR` (`{name:"Light",id:"light",`) and, with `THEME_SET_AS_DEFAULT=1`, replaces the single literal `"windows":null)||"dark"` (the tail of Emby's `DefaultTheme` expression) with `||"embymalism"`; the other `||"dark"` in the file (the `"auto"` branch for native apps) is deliberately not matched. It refuses (file untouched) unless each anchor occurs exactly once and nothing of ours is present. All matching is fixed-string (`grep -F`, quoted bash pattern substitution) because the entry contains `[`, `]`, `!`.
- `theme_verify_patched` requires entry once, anchor once, the two adjacent, and the default literal in exactly the state the mode requires. PHASE 9/9 runs it against the file **inside the container** and additionally checks that stripping the entry from the installed file yields the baseline byte-for-byte.
- The entry mirrors Emby's own derived themes (Blue Radiance/Superman reuse `darkgradient` sheets by path): Dark's sheets plus `modules/themes/embymalism/theme.css` last, `requires:["cssvariables"]`, `skipForSettingsthemes:!0`, no `isDefault` (recomputed at runtime from `DefaultTheme`). A default theme sidesteps Emby's Premiere check, which only applies to non-default themes chosen by hand.
- `THEME_MODE` (`theme` | `customcss`) selects the path in PHASE 7/8/9, `rollback()` and the generated scripts; the manifest records `theme.mode`, `theme.default_for_all_users` and `theme.fallback_reason`. In theme mode the Branding `POST` sends `{"CustomCss": ""}` and PHASE 9/9 verifies the live value hashes to the empty string.
- Client caching: Emby's module loader appends `?v=<data-appversion>` (injected by the server into the served `index.html`) and serves modules with a one-year `Cache-Control`; nginx in front may cache `.js` for a day. The installer cannot change that version; `deploy/nginx/purge-assets.sh` and the README's one-time browser step cover it. `serviceworker.js` is empty in web mode.

Why not `:has()`/route-based CSS scoping or a JS shim: those were prototyped first and each missed the JS-rendered admin pages, depended on how a page was reached, or shipped a script of our own; the theme entry uses Emby's own switching mechanism and covers exactly the routes Emby defines as settings.

### Third-party API keys and the API proxy

`EMBY_API_KEY` never leaves the host (`curl -K` config file, never an argument, never in a generated script). TMDB/MDBList/Kinopoisk keys are used by the addons **from the browser**, which upstream solves by embedding them in the JS. With `API_PROXY_URL` set the installer instead injects `API_KEY_PLACEHOLDER` where it would inject each key (the optional-key conditionals still key off the real value being configured), rewrites the API bases in the four addons that call them, asserts with `assert_no_third_party_keys` that no real key *value* survives in a staged addon (values passed via process substitution, never as arguments), and smoke-tests the proxy (`tmdb/3/configuration` with the placeholder, `Referer` set to the Emby URL, optional `--resolve` to a LAN IP because a NAS usually cannot hairpin to its own public address) — warn-only by design.

On the nginx side, `conf.d/emby-api-cache.conf` (http context, so `nginx.conf` is untouched) holds the cache zone, the `map` that strips `api_key`/`apikey` from `$args`, the rate-limit zone and the client-origin maps (same-origin by PCRE back-reference against `$scheme://$host`, plus RFC1918 origins — nothing hardcoded); the three `location ^~` blocks in `snippets/emby-api-proxy.conf` share `snippets/emby-api-common.conf`; real keys are `map` constants in `snippets/emby-api-keys.conf` (`600`). The cache key excludes the key, so every user shares one entry per request.

## Failure state machine

*What happens if the process dies exactly after each mutation?* Handled by the in-process `rollback()` (triggered by the `ERR` trap, `INT`/`TERM`, or `die_critical` once `INSTALL_STARTED=1`):

| Died right after... | State left behind | What `rollback()` does |
|---|---|---|
| `INSTALL_STARTED=1`, nothing copied | Container untouched | Effectively a no-op, correctly. |
| `docker cp` of addon *N* | Addons 1..N new, the rest old | Each addon restored from backup or deleted if it did not exist before. |
| All addons copied, before `index.html` | New addons, original `index.html` | Same per-addon restore. |
| `index.html` copied, before the theme files | New addons + `index.html` | Both restored from backup. |
| Theme files copied, before the Branding `POST` | Patched `skinmanager.js`, `theme.css` present | `skinmanager.js` restored (`restore_or_warn_file`), `theme.css` restored or removed (`restore_or_remove_file`). |
| Branding `POST` fails | Everything new, Branding old | **Not rolled back** (non-critical): warning, exit `2`, retry the step. |
| During PHASE 9/9 verification | Everything installed, a check failed | Full restore — a verification failure is an install failure. |

**Three rollback paths, one source of truth.** `rollback()` (in-process), the generated `rollback-<timestamp>.sh` (manual, later) and `rollback_reapply()` (inside `reapply-<timestamp>.sh`) all restore files by hash-verified copy and the CustomCss via the API, and all must stay usable independently (the generated scripts are self-contained and re-source `secrets/api.env` at their own runtime). The restore logic is defined once as literal text (`SHARED_RESTORE_FUNCTIONS`, a quoted heredoc captured with `read -r -d ''`), `eval`'d into this process and inserted byte-for-byte into the unquoted generation heredocs. Every call site guards these functions with `if …; then … else rc=$?; fi` — a bare `fn; rc=$?` aborts the whole script under `set -e` the moment `fn` returns non-zero.

Lessons that shaped this section, all found by *running* the failure paths against `docker`/`curl` stubs rather than reading the code: `rollback()` once did not exist at all (`rollback || true` swallowed "command not found" while the log still said a rollback ran); the generated rollback script once exited `0` unconditionally; hash-verification reads once lacked `|| true` and aborted the restore loop from inside `rollback()`. `tests/integration/` executes this table so those cannot silently return.

## Failure and exit code contract

`INSTALL_RESULT` (`SUCCESS` | `DEGRADED` | `FAILED`) and `ROLLBACK_RESULT` (`NOT_NEEDED` | `SUCCESS` | `PARTIAL` | `FAILED`) are tracked separately and never conflated. `ROLLBACK_RESULT` comes from step-by-step tracking, never from `rollback()`'s return code (kept `0` so it never re-triggers the trap). Exit codes: `0` success, `2` degraded (CSS `POST` failed or declined), `1` failed **regardless of `ROLLBACK_RESULT`** — recovery never improves the exit status; both values are logged for a human. An interrupt before `INSTALL_STARTED=1` is a benign cancellation (exit `0`); after it, it is treated like `die_critical`.

## Reapply recovery model

`reapply-<timestamp>.sh` is scoped to what it touches (addons, `index.html`, in theme mode `skinmanager.js` + `theme.css`, and the Branding step). It takes its own lightweight backup of whatever currently exists before copying (each `docker cp`/`GET` best-effort, since right after a container recreation there may be nothing to back up), then sets `REAPPLY_STARTED=1`. It cannot know whether it runs after a recreation (nothing to lose) or as an ad hoc fix on a working container (real state to lose), so it always backs up first. Its exit contract mirrors the installer's; the lightweight backup directory is deleted on success and kept (path printed) on failure.

## Concurrency

A `flock -n` on `$BASE/.install-emby-custom.lock`, held via an open descriptor for the whole run and released by the kernel however the process exits. Non-blocking on purpose (a queued second run in cron could race a third); scoped to `BASE`, so different Emby instances can install in parallel while runs against the same one are serialized. `flock` assumes POSIX semantics that NFS/CIFS may not honor: the script detects a network filesystem (`stat -f -c '%T'`) and warns. The lock does not cover the container being recreated by something else mid-run, so the container `Id` captured at detection is re-verified immediately before backup and before install.

## Verification model: integrity vs. health

PHASE 9/9 proves **deployment integrity** (files exist, sizes, SHA256 inside the container, key absence, `index.html` references, theme-entry structure, Branding value), not **application health** (that the UI renders, that no injected JS throws). That is why the final summary ends with "reload with Ctrl+Shift+R and look", and why `--status` compares hashes rather than claiming the UI works.

## Supply chain

Addon URLs point at upstream `main`; `known-source-sha256sums.txt` detects when that changes (warn and proceed by default, `--require-known-hashes` to block, `--check-updates` to report without installing, `CSS_PIN_REF` to pin the stylesheet). The new baseline is only committed once PHASE 9/9 passes: hashes are staged in a temp file during download, so a run that downloads a changed addon and dies later leaves the last known-good hashes intact.

## Retention

`prune_old_artifacts` runs only at the end of a successful install, keeps the newest `BACKUP_RETENTION_COUNT` `backups/<timestamp>/` directories and deletes older ones with their correlated `custom/*-<timestamp>.*` files and `$SCRIPT_DIR/emby-backup-<timestamp>.tgz`, so a pruned run never leaves a rollback script pointing at a missing backup. The portable `.tgz` and `.emby-installer-state` live next to the script rather than under `BASE` because both must survive `BASE` itself becoming the problem; `rollback-<timestamp>.sh` only reaches for the `.tgz` when `backups/<timestamp>/` is missing.

## Other design decisions worth knowing before changing

- **The Branding step is a full replace, not a merge** — predictability over preserving unknown prior CSS; recoverable from `branding-before.json`.
- **The CSS is served from Emby's own files, never via `@import url(...)`** — early versions made every page load depend on GitHub; now the downloaded, hash-verified file is copied to `theme.css` (or JSON-escaped into `CustomCss` in fallback mode), read with `IFS= read -r -d ''` rather than `$(cat)` (which strips trailing newlines and produced a false verification mismatch in a real install, as did `jq -r` appending one — hence `jq -j`).
- **`skinmanager.js` is patched, not replaced** — one literal at one unique anchor, persisted baseline, structural verification inside the container, byte-for-byte "strip gives back the original" check, automatic fallback.
- **No Python dependency** — POSIX `sed`/`awk`/`grep`; `node` and `jq` optional.
- **Silent-mode secrets come from environment variables, never CLI flags** (shell history, `ps`).
- **Generated scripts read `secrets/api.env` at their own runtime** instead of embedding the key (a reference implementation once embedded it — a real gap).
- **Every value interpolated into the generation heredocs is shell-quoted** (`shell_single_quote`): `EMBY_URL`/`CONTAINER`/`BASE` are only validated by "did it answer", which does not rule out metacharacters.
- **`EMBY_API_KEY` is never a `curl` argument** (`-K` config file, chmod 600).
- **`.emby-installer-state` is written atomically and `chmod 600`** — no secret, but in `--silent` mode it decides what gets mutated.
- **`secrets/api.env` ownership/permission check is Unix-bits-only, not ACL-aware** — a known gap on ZFS ACLs, judged out of scope.
- **Code, comments and user-facing messages are in English**; the only Spanish left in the installer is the German→Spanish phrase table for `emby-elsewhere.js` (`ELSEWHERE_UI_LANGUAGE="es"`).

---

# Español

## Compatibilidad y versiones futuras de Emby

El script apunta a una versión conocida (`TESTED_EMBY_VERSION`, al principio) y lo dice en vez de adivinar formas de API que nunca vio. Cada corrida consulta la versión real del servidor (`/emby/System/Info/Public`), avisa si difiere (nunca falla) y la registra en el manifest para correlacionar después. No trae fallbacks especulativos para rutas de Branding o layouts de `dashboard-ui` hipotéticos; en cambio mantiene lo más propenso a cambiar como constantes con nombre (`EMBY_BRANDING_GET_PATH`, `EMBY_BRANDING_POST_PATH`, `DASHBOARD_CONTAINER_DIR`, `SKINMANAGER_REL`, las anclas `THEME_*`, `API_BASE_*`), falla ruidosamente con el status/endpoint exacto cuando una llamada a Branding se porta raro, y falla ruidosamente nombrando la declaración faltante cuando desaparece el punto de inyección de un addon. El único lugar donde degrada en vez de fallar es el registro del tema: si el ancla de `skinmanager.js` no aparece exactamente una vez, cae a `CustomCss` de Branding con un aviso, porque "las páginas de administración se ven mal otra vez" es mejor resultado tras una actualización de Emby que "sin tema".

## Configuración: constantes del script vs. archivo de configuración

Hay tres tipos de valores. **Constantes técnicas** (rutas dentro del container, endpoints de API, URLs de upstream, anclas) son código y quedan en el script. **Valores de despliegue y de producto** (URLs de proxies, IP de LAN para el smoke test, región, idiomas, ajustes de Spotlight/ratings, retención, tema por defecto) tienen defaults deliberadamente genéricos en el script y toman sus valores reales de `install-emby-custom.conf` (lista blanca `CONFIG_KEYS`, `load_config_file`). **Secretos** solo en `secrets/api.env`.

El archivo de configuración se **parsea, nunca se "sourcea"**: cada línea debe ser `KEY=valor`, la clave debe estar en `CONFIG_KEYS`, y el valor se valida por tipo (`CONFIG_BOOL_KEYS`, `CONFIG_INT_KEYS`, `CONFIG_URL_SLASH_KEYS`, más reglas por clave para forma de URL, IPv4, código de región, volumen, calidad de video) y se rechaza si contiene `$` o backticks. La asignación es `printf -v`, así que nada del archivo puede ejecutarse. Las claves de lista llegan como `a|b|c` y se parten en los arrays que esperan los helpers. Precedencia: flag > archivo > default; el archivo se carga cuando ya existen `die_precheck`/`warn` (sección 4b) y los valores derivados (`CSS_URL`, los `*_CORS_PROXY_URL` por addon) se calculan después. `--print-config` imprime el conjunto efectivo con `%q` y sale sin tocar nada. `tests/unit/test_config_file.sh` valida además cada clave del `.conf.example` versionado con el cargador real, así la plantilla nunca puede documentar una clave que el script rechace.

## Mecanismos de inyección en los addons

Cada addon expone sus valores configurables en el formato que eligió su autor:

| Archivo | Formato | Ejemplo |
|---|---|---|
| `emby-elsewhere.js`, `Reviews.js` | `const NAME = value;` | `const MAX_REVIEWS = 30;` |
| `Spotlight.js`, `emby-ratings.js` | propiedad de objeto | `TMDB_API_KEY: 'x',` |

Dos familias independientes de helpers basados en `sed` lo manejan. `set_or_die_const_string` / `set_or_inject_const_string` / `set_or_inject_const_raw` / `set_or_inject_const_array_raw` / `set_if_declared_const_string` / `verify_or_warn_const_raw` para el estilo `const` (algunos inyectan una declaración faltante, otros la exigen; `set_if_declared_const_string` hace cumplir "nunca agregar `TMDB_API_KEY` a `Reviews.js` si no estaba"; la variante de array necesita su propia verificación porque `[`/`]` son metacaracteres ERE). `set_or_die_property_string` / `set_or_die_property_raw` para el estilo propiedad, preservando la comilla original, la coma final (esté o no) y cualquier comentario en línea re-emitiendo intacto todo lo que sigue al valor.

Ambas familias exigen que el objetivo exista exactamente una vez (salvo donde se indica) y hacen `die_precheck` nombrándolo si no — nunca un salto silencioso. Dos familias acotadas son más fáciles de verificar que una regex ingeniosa que tuviera que cubrir ambas formas con y sin comas/comentarios. La verificación posterior se ancla a la declaración misma (`NAME[:=]\s*(['"])value\1` al inicio de línea), no a una búsqueda de substring en todo el archivo: una región de dos letras o un `CORS_PROXY_URL` vacío matchearían trivialmente y taparían un `sed` que no cambió nada.

`rewrite_api_base` (modo API proxy) es el tercer helper: conteo literal de la base de URL, `sed` con patrón y reemplazo escapados, y verificación de que no queda ninguna original y hay al menos tantas reescritas. Sus conteos usan `{ grep -o … || true; } | wc -l` porque `grep -o` sale con 1 sin coincidencias, lo que con `pipefail` + el trap `ERR` del script abortó una instalación real aunque "cero originales restantes" es justamente el resultado correcto (bash ignora `set -e` dentro de sustituciones de comandos pero el trap igual dispara) — `tests/unit/test_api_proxy_rewrite.sh` lo reproduce bajo `set -E` + `trap ERR`.

### Registro del tema en `modules/skinmanager.js`

Embymalism no se instala como `CustomCss` de Branding (que `app.js` carga una vez, global, sin importar el tema activo) sino como entrada de la lista de temas de Emby, así está activo solo como tema principal y nunca en las vistas de administración/configuración, que corren bajo el *Settings theme* aparte. Mecánica (PHASE 6/9 "Preparación del tema", helpers `theme_*`):

- `AllThemes` en `skinmanager.js` es un array literal hardcodeado sin punto de extensión. El archivo se trata como `index.html`: se trae la copia del container, se le quita nuestra entrada si está (`theme_strip_entry`, eliminación literal tanto de la entrada como del literal del tema por defecto, sin importar el modo actual), se compara con el baseline `custom/skinmanager.js.original` (refrescado cuando la copia de Emby cambió) y se re-inyecta desde ese baseline en cada corrida.
- `theme_inject_entry` inserta `THEME_ENTRY` justo antes de `THEME_ANCHOR` (`{name:"Light",id:"light",`) y, con `THEME_SET_AS_DEFAULT=1`, reemplaza el único literal `"windows":null)||"dark"` (final de la expresión `DefaultTheme` de Emby) por `||"embymalism"`; el otro `||"dark"` del archivo (rama `"auto"` de apps nativas) no se toca a propósito. Se niega (archivo intacto) salvo que cada ancla aparezca exactamente una vez y no haya nada nuestro. Todo el matching es literal (`grep -F`, sustitución de bash con patrón entre comillas) porque la entrada contiene `[`, `]`, `!`.
- `theme_verify_patched` exige entrada una vez, ancla una vez, ambas contiguas y el literal del default en el estado exacto del modo. PHASE 9/9 lo corre sobre el archivo **dentro del container** y además comprueba que quitando la entrada del instalado se obtiene el baseline byte a byte.
- La entrada imita los temas derivados de Emby (Blue Radiance/Superman reutilizan las hojas de `darkgradient` por ruta): las hojas de Dark más `modules/themes/embymalism/theme.css` al final, `requires:["cssvariables"]`, `skipForSettingsthemes:!0`, sin `isDefault` (se recalcula en runtime desde `DefaultTheme`). Un tema por defecto evita el chequeo de Premiere de Emby, que solo aplica a temas no-default elegidos a mano.
- `THEME_MODE` (`theme` | `customcss`) selecciona el camino en PHASE 7/8/9, `rollback()` y los scripts generados; el manifest registra `theme.mode`, `theme.default_for_all_users` y `theme.fallback_reason`. En modo tema el `POST` de Branding manda `{"CustomCss": ""}` y PHASE 9/9 verifica que el valor vivo hashea a la cadena vacía.
- Caché del cliente: el cargador de módulos de Emby agrega `?v=<data-appversion>` (inyectado por el servidor en el `index.html` servido) y sirve los módulos con `Cache-Control` de un año; un nginx delante puede cachear los `.js` un día. El instalador no puede cambiar esa versión; `deploy/nginx/purge-assets.sh` y el paso único por navegador del README lo cubren. `serviceworker.js` está vacío en modo web.

Por qué no scoping CSS con `:has()`/por ruta ni un shim JS: se prototiparon primero y cada uno se perdía las páginas de administración renderizadas por JS, dependía de cómo se llegaba a la página o embarcaba un script propio; la entrada de tema usa el propio mecanismo de cambio de Emby y cubre exactamente las rutas que Emby define como settings.

### Keys de terceros y el API proxy

`EMBY_API_KEY` nunca sale del host (archivo de config de `curl -K`, nunca argumento, nunca en un script generado). Las keys de TMDB/MDBList/Kinopoisk las usan los addons **desde el navegador**, lo que upstream resuelve embebiéndolas en el JS. Con `API_PROXY_URL` configurado, el instalador inyecta `API_KEY_PLACEHOLDER` donde inyectaría cada key (los condicionales de keys opcionales siguen mirando el valor real configurado), reescribe las bases de API en los cuatro addons que las usan, afirma con `assert_no_third_party_keys` que ningún *valor* de key real sobrevive en un addon preparado (valores por process substitution, nunca como argumento) y prueba el proxy (`tmdb/3/configuration` con el placeholder, `Referer` con la URL de Emby, `--resolve` opcional a una IP de LAN porque un NAS normalmente no puede hacer hairpin a su propia IP pública) — solo aviso, por diseño.

Del lado nginx, `conf.d/emby-api-cache.conf` (contexto http, así `nginx.conf` no se toca) tiene la zona de caché, el `map` que quita `api_key`/`apikey` de `$args`, la zona de rate limit y los maps de origen del cliente (mismo origen por retrorreferencia PCRE contra `$scheme://$host`, más orígenes RFC1918 — nada hardcodeado); las tres `location ^~` de `snippets/emby-api-proxy.conf` comparten `snippets/emby-api-common.conf`; las keys reales son constantes `map` en `snippets/emby-api-keys.conf` (`600`). La clave de caché excluye la key, así todos los usuarios comparten una entrada por pedido.

## Máquina de estados de fallo

*¿Qué pasa si el proceso muere justo después de cada mutación?* Lo maneja `rollback()` en el mismo proceso (disparado por el trap `ERR`, `INT`/`TERM` o `die_critical` una vez que `INSTALL_STARTED=1`):

| Murió justo después de... | Estado que queda | Qué hace `rollback()` |
|---|---|---|
| `INSTALL_STARTED=1`, nada copiado | Container intacto | En la práctica no-op, correctamente. |
| `docker cp` del addon *N* | Addons 1..N nuevos, el resto viejos | Cada addon restaurado desde el backup o eliminado si no existía antes. |
| Todos los addons copiados, antes de `index.html` | Addons nuevos, `index.html` original | Misma restauración por addon. |
| `index.html` copiado, antes de los archivos del tema | Addons + `index.html` nuevos | Ambos restaurados desde el backup. |
| Archivos del tema copiados, antes del `POST` de Branding | `skinmanager.js` parcheado, `theme.css` presente | `skinmanager.js` restaurado (`restore_or_warn_file`), `theme.css` restaurado o eliminado (`restore_or_remove_file`). |
| Falla el `POST` de Branding | Todo nuevo, Branding viejo | **No se revierte** (no crítico): aviso, exit `2`, reintentar el paso. |
| Durante la verificación de PHASE 9/9 | Todo instalado, un chequeo falló | Restauración completa — un fallo de verificación es un fallo de instalación. |

**Tres caminos de rollback, una sola fuente de verdad.** `rollback()` (en proceso), el `rollback-<timestamp>.sh` generado (manual, después) y `rollback_reapply()` (dentro de `reapply-<timestamp>.sh`) restauran archivos por copia verificada con hash y el CustomCss por la API, y todos deben seguir siendo usables por separado (los scripts generados son autocontenidos y re-leen `secrets/api.env` en su propio runtime). La lógica de restauración se define una sola vez como texto literal (`SHARED_RESTORE_FUNCTIONS`, un heredoc entre comillas capturado con `read -r -d ''`), se `eval`úa en este proceso y se inserta byte a byte en los heredocs de generación sin comillas. Cada punto de llamada envuelve estas funciones en `if …; then … else rc=$?; fi` — un `fn; rc=$?` a secas aborta todo el script bajo `set -e` apenas `fn` devuelve distinto de cero.

Lecciones que dieron forma a esta sección, todas encontradas *ejecutando* los caminos de fallo contra stubs de `docker`/`curl` y no leyendo el código: `rollback()` no existió durante un tiempo (`rollback || true` tragaba el "command not found" mientras el log decía que el rollback corrió); el script de rollback generado salió alguna vez con `0` incondicionalmente; las lecturas de verificación por hash carecían de `|| true` y cortaban el loop de restauración desde adentro de `rollback()`. `tests/integration/` ejecuta esta tabla para que eso no vuelva en silencio.

## Contrato de fallo y códigos de salida

`INSTALL_RESULT` (`SUCCESS` | `DEGRADED` | `FAILED`) y `ROLLBACK_RESULT` (`NOT_NEEDED` | `SUCCESS` | `PARTIAL` | `FAILED`) se llevan por separado y nunca se mezclan. `ROLLBACK_RESULT` sale del seguimiento paso a paso, nunca del código de retorno de `rollback()` (que se mantiene en `0` para no re-disparar el trap). Códigos: `0` éxito, `2` degradado (falló o se rechazó el `POST` del CSS), `1` fallo **sin importar `ROLLBACK_RESULT`** — la recuperación nunca mejora el exit status; ambos valores se loguean para un humano. Una interrupción antes de `INSTALL_STARTED=1` es una cancelación benigna (exit `0`); después, se trata como `die_critical`.

## Modelo de recuperación de reapply

`reapply-<timestamp>.sh` se limita a lo que toca (addons, `index.html`, en modo tema `skinmanager.js` + `theme.css`, y el paso de Branding). Toma su propio backup liviano de lo que exista antes de copiar (cada `docker cp`/`GET` a mejor esfuerzo, porque justo tras una recreación puede no haber nada que respaldar) y recién entonces pone `REAPPLY_STARTED=1`. No puede saber si corre tras una recreación (nada que perder) o como arreglo puntual en un container que funciona (estado real que perder), así que siempre respalda primero. Su contrato de salida espeja el del instalador; el directorio del backup liviano se borra en éxito y se conserva (ruta impresa) en fallo.

## Concurrencia

Un `flock -n` sobre `$BASE/.install-emby-custom.lock`, mantenido por un descriptor abierto toda la corrida y liberado por el kernel salga como salga el proceso. No bloqueante a propósito (una segunda corrida encolada en cron podría pisarse con una tercera); acotado a `BASE`, así distintas instancias de Emby pueden instalarse en paralelo mientras las corridas contra la misma se serializan. `flock` asume semántica POSIX que NFS/CIFS pueden no respetar: el script detecta filesystem de red (`stat -f -c '%T'`) y avisa. El lock no cubre que otra cosa recree el container a mitad de corrida, por eso el `Id` capturado en la detección se re-verifica justo antes del backup y antes de instalar.

## Modelo de verificación: integridad vs. salud

PHASE 9/9 prueba **integridad del despliegue** (los archivos existen, tamaños, SHA256 dentro del container, ausencia de keys, referencias en `index.html`, estructura de la entrada de tema, valor de Branding), no **salud de la aplicación** (que la UI renderice, que ningún JS inyectado lance error). Por eso el resumen final termina con "recargá con Ctrl+Shift+R y mirá", y por eso `--status` compara hashes en vez de afirmar que la UI funciona.

## Cadena de suministro

Las URLs de los addons apuntan a `main` de upstream; `known-source-sha256sums.txt` detecta cuándo eso cambia (avisar y seguir por defecto, `--require-known-hashes` para bloquear, `--check-updates` para informar sin instalar, `CSS_PIN_REF` para fijar la hoja de estilos). El nuevo baseline solo se consolida cuando PHASE 9/9 pasa: los hashes se guardan en un temporal durante la descarga, así una corrida que baja un addon cambiado y muere después deja intactos los últimos hashes buenos.

## Retención

`prune_old_artifacts` corre solo al final de una instalación exitosa, conserva los `BACKUP_RETENTION_COUNT` directorios `backups/<timestamp>/` más nuevos y borra los más viejos junto con sus `custom/*-<timestamp>.*` correlacionados y `$SCRIPT_DIR/emby-backup-<timestamp>.tgz`, así una poda nunca deja un rollback apuntando a un backup inexistente. El `.tgz` portátil y `.emby-installer-state` viven junto al script y no bajo `BASE` porque ambos deben sobrevivir a que `BASE` sea el problema; `rollback-<timestamp>.sh` solo recurre al `.tgz` cuando falta `backups/<timestamp>/`.

## Otras decisiones de diseño a conocer antes de cambiar

- **El paso de Branding es un reemplazo completo, no un merge** — previsibilidad por sobre preservar CSS previo desconocido; recuperable desde `branding-before.json`.
- **El CSS se sirve desde los propios archivos de Emby, nunca vía `@import url(...)`** — las primeras versiones hacían depender cada carga de GitHub; ahora el archivo descargado y verificado se copia a `theme.css` (o se escapa a JSON en `CustomCss` en modo fallback), leído con `IFS= read -r -d ''` y no con `$(cat)` (que recorta saltos de línea finales y produjo un falso mismatch en una instalación real, igual que `jq -r` agregando uno — de ahí `jq -j`).
- **`skinmanager.js` se parchea, no se reemplaza** — un literal en un ancla única, baseline persistido, verificación estructural dentro del container, chequeo byte a byte de "quitar devuelve el original", fallback automático.
- **Sin dependencia de Python** — `sed`/`awk`/`grep` POSIX; `node` y `jq` opcionales.
- **Los secretos en modo silencioso vienen por variables de entorno, nunca por flags** (historial del shell, `ps`).
- **Los scripts generados leen `secrets/api.env` en su propio runtime** en vez de embeber la key (una implementación de referencia la embebía — un hueco real).
- **Todo valor interpolado en los heredocs de generación va entrecomillado para el shell** (`shell_single_quote`): `EMBY_URL`/`CONTAINER`/`BASE` solo se validan por "¿respondió?", lo que no descarta metacaracteres.
- **`EMBY_API_KEY` nunca es argumento de `curl`** (archivo de config `-K`, chmod 600).
- **`.emby-installer-state` se escribe atómicamente y con `chmod 600`** — no es secreto, pero en `--silent` decide qué se muta.
- **El chequeo de dueño/permisos de `secrets/api.env` es solo de bits Unix, no de ACLs** — hueco conocido con ACLs de ZFS, fuera de alcance.
- **El código, los comentarios y los mensajes al usuario están en inglés**; el único español que queda en el instalador es la tabla de frases alemán→español de `emby-elsewhere.js` (`ELSEWHERE_UI_LANGUAGE="es"`).
