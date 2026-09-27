# deploy/ · SSH helpers and nginx files

**[English](#english) · [Español](#español)**

---

# English

Connection details for your hosts, kept **only locally**, plus the nginx files (CORS proxy, API proxy, fail2ban) and the helpers that install and test them.

## Setup (once)

```bash
cp deploy/truenas.env.example deploy/truenas.env      # fill in host, port, user, path to your private key
```

`truenas.env` is gitignored and is read straight from disk by the helpers — it never needs to be pasted anywhere. The private key itself stays where it already is (e.g. `~/.ssh/`); the file only points to it. `NGINX_HOST_REMOTE_*` are the same thing for the host that runs nginx.

## Helpers

```bash
./deploy/truenas-ssh.sh                          # interactive session on the Emby host
./deploy/truenas-ssh.sh -- docker ps -a           # one command
./deploy/truenas-ssh.sh --scp file.txt dest       # scp with the same settings
./deploy/nginx-ssh.sh -- nginx -t -c /etc/nginx/nginx.conf   # same, for the nginx host
```

Both use `StrictHostKeyChecking=accept-new`: a new host is accepted on first contact, a *changed* host key aborts.

`emby-reapply-watchdog.sh` runs on the Emby host from cron: it checks the addons, the `index.html` tags and the theme entry are still in the container and runs the newest `reapply-<timestamp>.sh` when an Emby update wiped them (`--dry-run` only reports). See the README, "Rollback, reapply, watchdog".

## nginx

`deploy/nginx/` **mirrors the nginx host**: every file goes to the same path it has under `deploy/nginx/` (e.g. `deploy/nginx/etc/nginx/conf.d/emby-api-cache.conf` → `/etc/nginx/conf.d/emby-api-cache.conf`). `nginx.conf` is never modified: `conf.d/*.conf` is already included in `http {}`, and the Emby `server {}` only needs two lines:

```nginx
include snippets/emby-cors-proxy.conf;
include snippets/emby-api-proxy.conf;
add_header Set-Cookie $emby_session_cookie;   # server level: reflects the Emby session into the /api-proxy/ cookie
```

nginx must be built with `--with-http_auth_request_module` (check `nginx -V`); `install.sh` adds all three lines when missing.

| File (under `deploy/nginx/etc/`) | Context | What |
|---|---|---|
| `nginx/snippets/emby-cors-proxy.conf` | `server` | Allow-listed CORS proxy for the Rotten Tomatoes / AlloCiné fallback and Elsewhere deep links |
| `nginx/conf.d/emby-api-cache.conf` | `http` | API proxy: cache zone, key-stripping map, client-origin maps (nothing hardcoded), rate-limit zone, include of the keys file |
| `nginx/snippets/emby-api-proxy.conf` | `server` | `location = /_emby_auth` (session check via `auth_request`: LAN source IP or the `emby_proxy_token` cookie validated against Emby) + the three `location ^~ /api-proxy/{mdblist,tmdb,kinopoisk}/` |
| `nginx/snippets/emby-api-common.conf` | — | Common body included by each API-proxy location |
| `nginx/snippets/emby-api-keys.conf.example` | `http` | Template of the real keys file (`map` constants). Copy to `emby-api-keys.conf`, chmod 600; generate it with `render-keys.sh` |
| `fail2ban/filter.d/emby-api-proxy.conf`, `fail2ban/jail.d/emby-api-proxy.conf` | fail2ban | Bans repeated 403/405/429 on `/api-proxy/` and `/cors-proxy/` |

Scripts in `deploy/nginx/`:

```bash
./deploy/nginx/render-keys.sh --from-truenas --out /tmp/keys.conf   # keys file from the NAS's secrets/api.env, never printed
./deploy/nginx/install.sh --vhost /etc/nginx/conf.d/emby.conf --keys /tmp/keys.conf --fail2ban
./deploy/nginx/check.sh https://emby.example.com --lan-origin http://192.168.1.10:8096
./deploy/nginx-ssh.sh -- /path/to/purge-assets.sh                  # after an install, drop nginx's cached addon files
```

`install.sh` uploads everything as `.new`, backs up the vhost, swaps the files, runs `nginx -t` **with the real config path** (`--nginx-conf` if it is not `/etc/nginx/nginx.conf`), reloads only on success and reverts everything otherwise; with `--fail2ban` it also installs the jail and reloads fail2ban. `check.sh` is the external test matrix (allowed targets 200 + CORS header + cache HIT, denied 403, preflight 204, POST 405, no key leaks). Always run `check.sh` after `install.sh`.

If your nginx layout differs (Debian `sites-available`, Nginx Proxy Manager, Docker): the snippets are plain `location` blocks and the `conf.d` file is plain `http`-context directives — put them wherever your setup includes such files (NPM: the snippets go into the proxy host's *Custom locations* / *Advanced* tab; the `http`-context file into a custom `conf.d` include).

## What does NOT go here

The API keys used by the installer live in `secrets/api.env` **inside the Emby data path on the NAS** (the wizard creates it). The optional key fields in `truenas.env.example` exist only to bootstrap a `--silent` run without the wizard, or to feed `render-keys.sh --from-env`.

---

# Español

Datos de conexión a tus hosts, guardados **solo localmente**, más los archivos de nginx (CORS proxy, API proxy, fail2ban) y los helpers que los instalan y prueban.

## Setup (una vez)

```bash
cp deploy/truenas.env.example deploy/truenas.env      # completá host, puerto, usuario y la ruta a tu clave privada
```

`truenas.env` está gitignored y los helpers lo leen directo del disco — nunca hace falta pegarlo en ningún lado. La clave privada queda donde ya esté (p. ej. `~/.ssh/`); el archivo solo apunta a ella. `NGINX_HOST_REMOTE_*` es lo mismo para el host donde corre nginx.

## Helpers

```bash
./deploy/truenas-ssh.sh                          # sesión interactiva en el host de Emby
./deploy/truenas-ssh.sh -- docker ps -a           # un comando puntual
./deploy/truenas-ssh.sh --scp archivo.txt destino # scp con la misma configuración
./deploy/nginx-ssh.sh -- nginx -t -c /etc/nginx/nginx.conf   # ídem, para el host de nginx
```

Ambos usan `StrictHostKeyChecking=accept-new`: un host nuevo se acepta en el primer contacto; una clave de host *cambiada* corta.

`emby-reapply-watchdog.sh` corre en el host de Emby desde cron: comprueba que los addons, los tags de `index.html` y la entrada del tema siguen en el container y ejecuta el `reapply-<timestamp>.sh` más reciente cuando una actualización de Emby los borró (`--dry-run` solo informa). Ver el README, "Rollback, reapply, watchdog".

## nginx

`deploy/nginx/` **espeja el host de nginx**: cada archivo va al mismo path que tiene bajo `deploy/nginx/` (p. ej. `deploy/nginx/etc/nginx/conf.d/emby-api-cache.conf` → `/etc/nginx/conf.d/emby-api-cache.conf`). `nginx.conf` nunca se modifica: `conf.d/*.conf` ya se incluye en `http {}`, y el `server {}` de Emby solo necesita dos líneas:

```nginx
include snippets/emby-cors-proxy.conf;
include snippets/emby-api-proxy.conf;
add_header Set-Cookie $emby_session_cookie;   # a nivel server: refleja la sesión de Emby en la cookie de /api-proxy/
```

nginx tiene que estar compilado con `--with-http_auth_request_module` (ver `nginx -V`); `install.sh` agrega las tres líneas si faltan.

| Archivo (bajo `deploy/nginx/etc/`) | Contexto | Qué es |
|---|---|---|
| `nginx/snippets/emby-cors-proxy.conf` | `server` | CORS proxy con lista blanca para el fallback de Rotten Tomatoes / AlloCiné y los deep-links de Elsewhere |
| `nginx/conf.d/emby-api-cache.conf` | `http` | API proxy: zona de caché, map que quita la key, maps de origen del cliente (nada hardcodeado), zona de rate limit, include del archivo de keys |
| `nginx/snippets/emby-api-proxy.conf` | `server` | `location = /_emby_auth` (chequeo de sesión vía `auth_request`: IP de origen en la LAN o la cookie `emby_proxy_token` validada contra Emby) + las tres `location ^~ /api-proxy/{mdblist,tmdb,kinopoisk}/` |
| `nginx/snippets/emby-api-common.conf` | — | Cuerpo común incluido por cada location del API proxy |
| `nginx/snippets/emby-api-keys.conf.example` | `http` | Plantilla del archivo real de keys (constantes `map`). Copiar a `emby-api-keys.conf`, chmod 600; generarlo con `render-keys.sh` |
| `fail2ban/filter.d/emby-api-proxy.conf`, `fail2ban/jail.d/emby-api-proxy.conf` | fail2ban | Banea 403/405/429 repetidos en `/api-proxy/` y `/cors-proxy/` |

Scripts en `deploy/nginx/`:

```bash
./deploy/nginx/render-keys.sh --from-truenas --out /tmp/keys.conf   # archivo de keys desde el secrets/api.env del NAS, sin imprimirlas
./deploy/nginx/install.sh --vhost /etc/nginx/conf.d/emby.conf --keys /tmp/keys.conf --fail2ban
./deploy/nginx/check.sh https://emby.example.com --lan-origin http://192.168.1.10:8096
./deploy/nginx-ssh.sh -- /ruta/a/purge-assets.sh                  # tras una instalación, descartar los addons cacheados por nginx
```

`install.sh` sube todo como `.new`, respalda el vhost, intercambia los archivos, corre `nginx -t` **con la ruta real de la config** (`--nginx-conf` si no es `/etc/nginx/nginx.conf`), recarga solo si pasa y revierte todo si no; con `--fail2ban` instala además la jail y recarga fail2ban. `check.sh` es la matriz de pruebas externa (destinos permitidos 200 + header CORS + HIT de caché, denegados 403, preflight 204, POST 405, sin fugas de keys). Corré siempre `check.sh` después de `install.sh`.

Si tu nginx tiene otra estructura (Debian `sites-available`, Nginx Proxy Manager, Docker): los snippets son bloques `location` planos y el archivo de `conf.d` son directivas planas de contexto `http` — ponelos donde tu instalación incluya ese tipo de archivos (NPM: los snippets van en *Custom locations* / *Advanced* del proxy host; el archivo de contexto `http` en un include propio de `conf.d`).

## Qué NO va acá

Las API keys que usa el instalador viven en `secrets/api.env` **dentro de la ruta de datos de Emby en el NAS** (las crea el wizard). Los campos opcionales de keys en `truenas.env.example` existen solo para bootstrapear una corrida `--silent` sin wizard, o para alimentar `render-keys.sh --from-env`.
