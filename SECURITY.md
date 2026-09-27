# Security · Seguridad

[English](#english) · [Español](#español) · Layer-by-layer detail: [docs/SECURITY-LAYERS.md](docs/SECURITY-LAYERS.md)

---

## English

### What this project touches

- **Your Emby container**: six addon `.js` files, `index.html`,
  `modules/skinmanager.js` (one theme entry inserted) and
  `modules/themes/embymalism/theme.css`. Everything is backed up first and
  restorable with the generated `rollback-<timestamp>.sh` or `--uninstall`.
- **Emby's Branding configuration** (`CustomCss`), replaced (normally emptied).
- Optionally **your nginx** (files under `deploy/nginx/`, never `nginx.conf`).

### Where secrets live and where they never go

| Secret | Lives in | Never appears in |
|---|---|---|
| `EMBY_API_KEY` | `secrets/api.env` on the host (chmod 600, owner-checked) | command lines (`curl -K` config file), logs, manifests, generated scripts, addons |
| TMDB / MDBList / Kinopoisk keys | `secrets/api.env`; with the API proxy also `snippets/emby-api-keys.conf` on nginx (chmod 600) | the addons served to browsers (a placeholder is injected instead; the install aborts if a real key value is found in a staged addon), the config file, logs |
| Deployment details (hosts, IPs, domain) | `install-emby-custom.conf`, `deploy/truenas.env` (both gitignored) | tracked files (CI fails if it finds them) |

### Supply chain

Addons and CSS are downloaded from upstream `main` on every run, hashed,
and compared with the hash of the last successful install
(`--require-known-hashes` turns a change into a hard stop); `CSS_PIN_REF`
pins the stylesheet to one commit. Every installed file is verified
byte-for-byte inside the container after copying.

### Reporting

This is a personal project. Open an issue describing the problem; do not
include your keys, hostnames or logs with tokens in it.

---

## Español

### Qué toca este proyecto

- **Tu container de Emby**: seis `.js` de addons, `index.html`,
  `modules/skinmanager.js` (una entrada de tema insertada) y
  `modules/themes/embymalism/theme.css`. Todo se respalda antes y se
  restaura con el `rollback-<timestamp>.sh` generado o con `--uninstall`.
- **La configuración de Branding de Emby** (`CustomCss`), reemplazada
  (normalmente vaciada).
- Opcionalmente **tu nginx** (archivos bajo `deploy/nginx/`, nunca `nginx.conf`).

### Dónde viven los secretos y dónde no van nunca

| Secreto | Vive en | Nunca aparece en |
|---|---|---|
| `EMBY_API_KEY` | `secrets/api.env` en el host (chmod 600, se verifica el dueño) | líneas de comando (`curl -K` con archivo de config), logs, manifests, scripts generados, addons |
| Keys de TMDB / MDBList / Kinopoisk | `secrets/api.env`; con el API proxy también `snippets/emby-api-keys.conf` en nginx (chmod 600) | los addons que se sirven al navegador (se inyecta un placeholder; la instalación aborta si encuentra una key real en un addon preparado), el archivo de configuración, logs |
| Datos del despliegue (hosts, IPs, dominio) | `install-emby-custom.conf`, `deploy/truenas.env` (ambos gitignored) | archivos versionados (la CI falla si los encuentra) |

### Cadena de suministro

Los addons y el CSS se descargan de la rama `main` de upstream en cada
corrida, se hashean y se comparan con el hash de la última instalación
exitosa (`--require-known-hashes` convierte un cambio en un freno);
`CSS_PIN_REF` fija la hoja de estilos a un commit. Cada archivo instalado
se verifica byte a byte dentro del container después de copiarlo.

### Reportes

Es un proyecto personal. Abrí un issue describiendo el problema; no
incluyas tus keys, hostnames ni logs con tokens.
