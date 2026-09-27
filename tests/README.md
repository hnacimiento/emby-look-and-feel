# Tests · Tests

**[English](#english) · [Español](#español)**

---

# English

```bash
./tests/run_tests.sh
```

Nothing to install — pure `bash` plus the coreutils the installer already requires (`sed`, `awk`, `grep`, `sha256sum`). No `bats`, `shunit2` or Python, on purpose: same "no extra dependencies" philosophy as the rest of the project.

## What is here

- **`unit/`** — pure functions of the script: escaping helpers (`sed`/`grep`/JSON/curl-config), the two families of addon-injection helpers, CSS embedding (including the trailing-newline regression), theme injection into `skinmanager.js` (anchors, idempotence, both default-theme modes), the API-proxy base rewrite and real-key guard (including the `pipefail` + `trap ERR` regression), and the config-file loader (allow-list, types, no shell evaluation, every key of the tracked `.conf.example`). The functions are **extracted from the real `install-emby-custom.sh`** at test time (`lib/extract_functions.sh`) — never copied by hand, so a test always exercises the code as it is today.

- **`integration/`** — generates the **real** `rollback-<timestamp>.sh` and `reapply-<timestamp>.sh` (the same heredocs the installer writes, materialized with test paths — `lib/container_stub.sh`) and runs them against fake `docker`/`curl` (`stubs/`) that simulate success, partial failures, missing backups, the portable `.tgz` fallback, theme mode (patched `skinmanager.js` + `theme.css`, empty Branding payload) and the failure paths of the "failure state machine" in `docs/ARCHITECTURE.md`. The historical bugs that motivated that section each have a dedicated test.

- **`fixtures/`** — small `.js` files mimicking the real shapes (`const NAME = value;`, `NAME: value,`).
- **`stubs/docker`, `stubs/curl`** — replacements controlled by `STUB_DOCKER_*` / `STUB_CURL_*` environment variables (see each file's header); `curl` can record the request bodies it receives (`STUB_CURL_RECORD_BODY_FILE`).
- **`lib/`** — `extract_functions.sh`, `container_stub.sh`, `test_helpers.sh` (a handful of pure-bash `assert_*`).

## What is NOT covered (yet)

- The full end-to-end flow of `install-emby-custom.sh` (PHASE 1/9 to 9/9): it chains real `docker`/`curl` calls with real state (container detection, credentials wizard). The closest thing today is `--dry-run` and `--status` against a real Emby.
- Anything that depends on the real content of the upstream addons (the German→English/Spanish translation, the exact number of API URLs) is tested with fixtures, not upstream files.

## Adding a function to the installer

Pure function (no `docker`/`curl`): add a unit test that extracts it with `source_functions`. Something that touches the install/rollback/reapply flow: consider a new `integration/` case with the stubs before trusting a code read. Remember the test suite asserts on the script's (Spanish) user-facing messages: changing a message means updating the assertion.

---

# Español

```bash
./tests/run_tests.sh
```

No hace falta instalar nada — `bash` puro más los coreutils que ya requiere el instalador (`sed`, `awk`, `grep`, `sha256sum`). Sin `bats`, `shunit2` ni Python, a propósito: la misma filosofía de "sin dependencias extra" que el resto del proyecto.

## Qué hay acá

- **`unit/`** — funciones puras del script: helpers de escaping (`sed`/`grep`/JSON/curl-config), las dos familias de helpers de inyección de addons, embebido de CSS (incluida la regresión del salto de línea final), inyección del tema en `skinmanager.js` (anclas, idempotencia, ambos modos de tema por defecto), reescritura de bases del API proxy y guarda de keys reales (incluida la regresión de `pipefail` + `trap ERR`), y el cargador del archivo de configuración (lista blanca, tipos, sin evaluación de shell, cada clave del `.conf.example` versionado). Las funciones se **extraen del `install-emby-custom.sh` real** en tiempo de test (`lib/extract_functions.sh`) — nunca se copian a mano, así que un test siempre ejercita el código tal como está hoy.

- **`integration/`** — genera los `rollback-<timestamp>.sh` y `reapply-<timestamp>.sh` **reales** (los mismos heredocs que escribe el instalador, materializados con rutas de prueba — `lib/container_stub.sh`) y los corre contra `docker`/`curl` de mentira (`stubs/`) que simulan éxito, fallos parciales, backups faltantes, el fallback al `.tgz` portátil, el modo tema (`skinmanager.js` parcheado + `theme.css`, payload de Branding vacío) y los caminos de fallo de la "máquina de estados de fallo" de `docs/ARCHITECTURE.md`. Cada bug histórico que motivó esa sección tiene su test dedicado.

- **`fixtures/`** — `.js` chicos que imitan las formas reales (`const NAME = value;`, `NAME: value,`).
- **`stubs/docker`, `stubs/curl`** — reemplazos controlados por variables `STUB_DOCKER_*` / `STUB_CURL_*` (ver la cabecera de cada uno); `curl` puede registrar los cuerpos que recibe (`STUB_CURL_RECORD_BODY_FILE`).
- **`lib/`** — `extract_functions.sh`, `container_stub.sh`, `test_helpers.sh` (un puñado de `assert_*` en bash puro).

## Qué NO cubre (todavía)

- El flujo completo de `install-emby-custom.sh` de punta a punta (PHASE 1/9 a 9/9): encadena `docker`/`curl` reales con estado real (detección de container, wizard de credenciales). Lo más parecido hoy es `--dry-run` y `--status` contra un Emby real.
- Lo que depende del contenido real de los addons de upstream (la traducción alemán→inglés/español, la cantidad exacta de URLs de API) se prueba con fixtures, no contra los archivos de upstream.

## Si agregás una función al instalador

Función pura (sin `docker`/`curl`): agregá un test unitario que la extraiga con `source_functions`. Algo que toca el flujo de instalación/rollback/reapply: considerá un caso nuevo en `integration/` con los stubs antes de confiar en una lectura del código. Recordá que la suite afirma sobre los mensajes al usuario (en español) del script: cambiar un mensaje implica actualizar la aserción.
