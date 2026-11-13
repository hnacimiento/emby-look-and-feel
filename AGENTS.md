# Instructions for agents working on this repository

[English](#english) · [Español](#español)

## English

### Core rules
1. **No references to AI brands** in anything created here: code, comments, file names, documentation,
   metadata, commit messages, `Co-Authored-By` lines, PR descriptions. Exception: the name of the
   instruction file a tool reads by default.
2. **Stay inside the workspace** unless the maintainer explicitly allows otherwise. Temporary files go to
   `.tmp/` (ignored by git).
3. **Secrets** never go into messages, logs or versioned files. Real values live outside the repository
   (local, ignored files such as `deploy/truenas.env` and `install-emby-custom.conf`, or the maintainer's
   secret store); only `*.example` templates are versioned.
4. **Maintainer's folders:** anything the agent did not create belongs to the maintainer and is not touched
   without permission.
5. **Diagnosis:** measure before theorizing; if the maintainer repeats a symptom, the hypothesis is wrong;
   suspect your own change first; test again after touching configuration.
6. **Third-party personal data** (phone numbers, emails, names, conversations) is never copied into notes,
   PRs, issues, `.tmp/` or messages; it is pseudonymized or redacted. Sending it to an external service is
   the maintainer's decision.
7. **This repository is mirrored publicly.** Do not write internal addresses, hostnames, tokens or private
   paths into versioned files.

### Workflow
- The canonical repository is the maintainer's own git server (`origin`); GitHub is a read-only push
  mirror. Do not commit, merge or tag directly on GitHub: the mirror overwrites it.
- No push without the maintainer's explicit OK for that push.
- Enable the secret-scan hook once per clone: `git config core.hooksPath .githooks` (gitleaks; set
  `GITLEAKS` if the binary is not on `PATH`).
- Keep the documentation in sync with every code change (README and docs are bilingual; code and comments
  in English).
- If an `AGENTS.local.md` exists next to this file, read it too: it holds machine-local settings that are
  not versioned.

## Español

### Reglas núcleo
1. **Sin referencias a marcas de IA** en nada de lo que se cree: código, comentarios, nombres de archivos,
   documentación, metadatos, mensajes de commit, líneas `Co-Authored-By`, descripciones de PR. Excepción: el
   nombre del archivo de instrucciones que una herramienta lee por defecto.
2. **No salir del workspace** sin autorización expresa del mantenedor. Los temporales van a `.tmp/`
   (ignorado por git).
3. **Secretos:** nunca en mensajes, logs ni archivos versionados. Los valores reales viven fuera del repo
   (archivos locales ignorados como `deploy/truenas.env` e `install-emby-custom.conf`, o el almacén de
   secretos del mantenedor); solo se versionan las plantillas `*.example`.
4. **Carpetas del mantenedor:** lo que no creó el agente es del mantenedor; no se toca sin permiso.
5. **Diagnóstico:** medir antes de teorizar; si el mantenedor repite un síntoma, la hipótesis está mal;
   sospechar primero del cambio propio; volver a probar después de tocar configuración.
6. **Datos personales de terceros** (teléfonos, emails, nombres, conversaciones): no se copian a notas, PR,
   issues, `.tmp/` ni mensajes; se seudonimizan o se redactan. Mandarlos a un servicio externo es decisión
   del mantenedor.
7. **Este repo se espeja en público.** No escribas direcciones internas, hosts, tokens ni rutas privadas en
   archivos versionados.

### Flujo de trabajo
- El repo canónico está en el servidor git propio del mantenedor (`origin`); GitHub es un espejo de solo
  lectura. No hagas commits, merges ni tags directamente en GitHub: el espejo los pisa.
- Ningún push sin el OK explícito del mantenedor para ese push.
- Activá el hook de secretos una vez por clon: `git config core.hooksPath .githooks` (gitleaks; definí
  `GITLEAKS` si el binario no está en el `PATH`).
- Mantené la documentación al día con cada cambio de código (README y docs bilingües; código y comentarios
  en inglés).
- Si existe un `AGENTS.local.md` junto a este archivo, leelo también: tiene la configuración local de la
  máquina, que no se versiona.
