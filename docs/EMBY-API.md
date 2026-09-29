# Emby API, as this project observes it · La API de Emby, como la observa este proyecto

[English](#english) · [Español](#español) · Back to [README](../README.md) · Related: [docs/ARCHITECTURE.md](ARCHITECTURE.md)

---

## English

This is a **reference map of the Emby Server HTTP API as actually used by its
web client and add-ons** — not official Emby documentation, and not exhaustive.
It exists so a reader of this project can understand *what the installed add-ons
talk to*, *why they only work in web-based clients*, and *how a request is
shaped*. It was built by observing a live Emby 4.10 deployment (real client
traffic) plus the open-source legacy TV client, without decompiling anything.
For the authoritative, complete API, use your server's own `/emby/openapi` /
Swagger and Emby's official docs.

### Authentication model

Emby tags every request with a set of `X-Emby-*` identity fields. Older clients
sent them as **headers** (`X-Emby-Authorization: MediaBrowser Client="...",
Device="...", DeviceId="...", Version="...", UserId="..."` plus a token header);
current clients send the same fields **also as URL query parameters**. That
header/query-parameter duality matters for operations: the session token can
appear in the URL, so it lands in access logs unless redacted (see
[docs/SECURITY-LAYERS.md](SECURITY-LAYERS.md), layer 13).

| Field | Meaning |
|---|---|
| `X-Emby-Client` | Client name (`Emby Web`, `Emby for Android`, `Emby for Samsung`, …) |
| `X-Emby-Client-Version` | Client version |
| `X-Emby-Device-Name` | Human-readable device name |
| `X-Emby-Device-Id` | Stable per-device id (persists across sessions) |
| `X-Emby-Token` | **Session token — a credential**, equivalent to being logged in |
| `X-Emby-Language` | Client locale |

- **Login:** `POST /emby/Users/AuthenticateByName` with `{"Username","Pw"}` →
  returns an access token + the user object.
- **Logout:** `POST /emby/Sessions/Logout`.
- **Unauthenticated (login screen):** `GET /emby/Users/Public`,
  `GET /emby/System/Info/Public`. Everything else needs the token.

### Endpoint catalog, by function

**Library browsing (per user):**
`GET /emby/Users/{userId}` (profile) · `/Views` (libraries) · `/Items` (query
with filters) · `/Items/Latest` · `/Items/Resume` (continue watching) ·
`/Items/{itemId}` (detail) · `/Items/{itemId}/SpecialFeatures` · `/Intros` ·
`GET /emby/Items/{itemId}/Similar` · `GET /emby/Shows/{itemId}/Episodes` ·
`/Seasons` · home screen via `/Users/{userId}/HomeSections` +
`/Sections/<key>/Items`.

**Playback lifecycle (the core of the protocol):**
1. `POST /emby/Items/{itemId}/PlaybackInfo` — negotiate media source / bitrate /
   whether to transcode.
2. `POST /emby/Sessions/Playing` — "playback started".
3. `POST /emby/Sessions/Playing/Progress` — progress heartbeat every ~10s while
   playing; **by far the most frequent call** (drives "continue watching" and
   the live session state).
4. `POST /emby/Sessions/Playing/Stopped` — "playback ended".
- `POST /emby/Sessions/Capabilities/Full` — the client declares its capabilities.

**Streaming:**
- HLS (transcoded): `GET /emby/videos/{id}/master.m3u8` → `main.m3u8` →
  `hls1/main/{n}.ts` segments + `hls1/subs/{n}.vtt` subtitles.
- Direct (no transcode): `GET /emby/videos/{id}/original.mkv` | `original.mp4`
  (byte-range).
- Audio: `GET /emby/Audio/{id}/universal`.

**Sessions / real-time state:** `GET /emby/Sessions` (who is connected/playing) ·
`GET /embywebsocket?...` (server-push over WebSocket; a persistent connection
kept alive for hours by server-side pings).

**Images:** `GET /emby/Items/{itemId}/Images/{Primary|Backdrop|Thumb}`
(parameters `ImageTypeLimit`, `EnableImageTypes`).

**System / branding:** `GET /emby/System/Info` (auth) vs `/System/Info/Public` ·
`/System/Endpoint` · `/System/Configuration` · `/Branding/Configuration` (the
`CustomCss` field this installer manages) · `/web/configurationpages` ·
`/ScheduledTasks` · `/System/ActivityLog/Entries` · `/LiveTv/Channels`.

### Common query parameters

`Limit`, `Fields`, `ImageTypeLimit`, `EnableImageTypes`, `Recursive`,
`IncludeItemTypes`, `SortBy`/`SortOrder`, `ParentId`, `StartTimeTicks`
(playback position, in 100-nanosecond ticks — `10,000,000` = 1 second, Emby's
universal time unit), `MaxStreamingBitrate`, `EnableUserData`,
`EnableTotalRecordCount`, `PlaySessionId` (correlates all events of one
playback), `reqformat=json`.

### How this project's add-ons fit in

The add-ons this installer sets up (`emby-ratings.js`, `Reviews.js`,
`Spotlight.js`, `emby-elsewhere.js`) run **inside the web client** and hook into
the item-detail view (`/Users/{userId}/Items/{itemId}`). On opening a title they
read its `ProviderIds` (IMDb/TMDb) from Emby's own response and then call the
third-party rating APIs (TMDB / MDBList / Kinopoisk) — directly, or through the
nginx API proxy this project adds. So the add-ons are **not** Emby endpoints:
they are consumers of the same `Items/{itemId}` the client already fetches, plus
a fan-out to external APIs. This is exactly why they only apply to clients that
run the web UI (browsers, and any device opening Emby in a browser) and never to
the native TV/phone apps, whose UI is compiled separately — see
[docs/ARCHITECTURE.md](ARCHITECTURE.md).

---

## Español

Este es un **mapa de referencia de la API HTTP de Emby Server tal como la usan
de verdad su cliente web y los add-ons** — no es documentación oficial de Emby,
ni es exhaustivo. Existe para que quien lea este proyecto entienda *con qué
hablan los add-ons instalados*, *por qué solo funcionan en clientes web* y *qué
forma tiene un request*. Se armó observando un despliegue de Emby 4.10 en vivo
(tráfico real de clientes) más el cliente de TV viejo de código abierto, sin
decompilar nada. Para la API completa y autoritativa, usá el `/emby/openapi` /
Swagger de tu propio servidor y la documentación oficial de Emby.

### Modelo de autenticación

Emby marca cada request con un set de campos de identidad `X-Emby-*`. Los
clientes viejos los mandaban como **headers** (`X-Emby-Authorization:
MediaBrowser Client="...", Device="...", DeviceId="...", Version="...",
UserId="..."` más un header de token); los clientes actuales mandan los mismos
campos **también como parámetros de query en la URL**. Esa dualidad
header/query-param importa a nivel operativo: el token de sesión puede aparecer
en la URL, así que queda en los logs de acceso salvo que se enmascare (ver
[docs/SECURITY-LAYERS.md](SECURITY-LAYERS.md), capa 13).

| Campo | Qué es |
|---|---|
| `X-Emby-Client` | Nombre del cliente (`Emby Web`, `Emby for Android`, `Emby for Samsung`, …) |
| `X-Emby-Client-Version` | Versión del cliente |
| `X-Emby-Device-Name` | Nombre legible del dispositivo |
| `X-Emby-Device-Id` | ID estable por dispositivo (persiste entre sesiones) |
| `X-Emby-Token` | **Token de sesión — una credencial**, equivale a estar logueado |
| `X-Emby-Language` | Locale del cliente |

- **Login:** `POST /emby/Users/AuthenticateByName` con `{"Username","Pw"}` →
  devuelve un token de acceso + el objeto usuario.
- **Logout:** `POST /emby/Sessions/Logout`.
- **Sin autenticar (pantalla de login):** `GET /emby/Users/Public`,
  `GET /emby/System/Info/Public`. Todo lo demás necesita el token.

### Catálogo de endpoints, por función

**Navegación de biblioteca (por usuario):**
`GET /emby/Users/{userId}` (perfil) · `/Views` (bibliotecas) · `/Items`
(consulta con filtros) · `/Items/Latest` · `/Items/Resume` (continuar viendo) ·
`/Items/{itemId}` (detalle) · `/Items/{itemId}/SpecialFeatures` · `/Intros` ·
`GET /emby/Items/{itemId}/Similar` · `GET /emby/Shows/{itemId}/Episodes` ·
`/Seasons` · pantalla de inicio vía `/Users/{userId}/HomeSections` +
`/Sections/<clave>/Items`.

**Ciclo de vida de reproducción (el corazón del protocolo):**
1. `POST /emby/Items/{itemId}/PlaybackInfo` — negocia fuente / bitrate / si
   transcodifica.
2. `POST /emby/Sessions/Playing` — "empecé a reproducir".
3. `POST /emby/Sessions/Playing/Progress` — heartbeat de progreso cada ~10s
   mientras se reproduce; **por lejos el request más frecuente** (alimenta
   "continuar viendo" y el estado de sesión en vivo).
4. `POST /emby/Sessions/Playing/Stopped` — "terminó la reproducción".
- `POST /emby/Sessions/Capabilities/Full` — el cliente declara sus capacidades.

**Streaming:**
- HLS (transcodificado): `GET /emby/videos/{id}/master.m3u8` → `main.m3u8` →
  segmentos `hls1/main/{n}.ts` + subtítulos `hls1/subs/{n}.vtt`.
- Directo (sin transcode): `GET /emby/videos/{id}/original.mkv` | `original.mp4`
  (byte-range).
- Audio: `GET /emby/Audio/{id}/universal`.

**Sesiones / estado en tiempo real:** `GET /emby/Sessions` (quién está
conectado/reproduciendo) · `GET /embywebsocket?...` (push del servidor por
WebSocket; una conexión persistente que se mantiene viva horas con pings del
lado servidor).

**Imágenes:** `GET /emby/Items/{itemId}/Images/{Primary|Backdrop|Thumb}`
(parámetros `ImageTypeLimit`, `EnableImageTypes`).

**Sistema / branding:** `GET /emby/System/Info` (con auth) vs `/System/Info/Public`
· `/System/Endpoint` · `/System/Configuration` · `/Branding/Configuration` (el
campo `CustomCss` que gestiona este instalador) · `/web/configurationpages` ·
`/ScheduledTasks` · `/System/ActivityLog/Entries` · `/LiveTv/Channels`.

### Parámetros de query más comunes

`Limit`, `Fields`, `ImageTypeLimit`, `EnableImageTypes`, `Recursive`,
`IncludeItemTypes`, `SortBy`/`SortOrder`, `ParentId`, `StartTimeTicks`
(posición de reproducción, en ticks de 100 nanosegundos — `10.000.000` = 1
segundo, la unidad de tiempo universal de Emby), `MaxStreamingBitrate`,
`EnableUserData`, `EnableTotalRecordCount`, `PlaySessionId` (correlaciona todos
los eventos de una reproducción), `reqformat=json`.

### Cómo encajan los add-ons de este proyecto

Los add-ons que instala este proyecto (`emby-ratings.js`, `Reviews.js`,
`Spotlight.js`, `emby-elsewhere.js`) corren **dentro del cliente web** y se
enganchan en la vista de detalle del ítem (`/Users/{userId}/Items/{itemId}`).
Al abrir un título leen su `ProviderIds` (IMDb/TMDb) de la respuesta del propio
Emby y con eso llaman a las APIs de ratings de terceros (TMDB / MDBList /
Kinopoisk) — directo, o a través del API proxy de nginx que agrega este
proyecto. Es decir, los add-ons **no** son endpoints de Emby: son consumidores
del mismo `Items/{itemId}` que el cliente ya pide, más un fan-out a APIs
externas. Por eso mismo solo aplican a clientes que ejecutan la UI web
(navegadores, y cualquier dispositivo que abra Emby en un navegador) y nunca a
las apps nativas de TV/celular, cuya UI se compila aparte — ver
[docs/ARCHITECTURE.md](ARCHITECTURE.md).
