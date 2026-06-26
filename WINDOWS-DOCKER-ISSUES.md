# Worklenz — Issues Found Running Docker Compose on Windows (localhost)

**Environment:** Windows 11, Docker Compose v5.1.3
**Command:** `docker compose --profile express up -d --build`
**Config:** `DOMAIN=localhost` (nginx self-signed SSL, `https://localhost`)

While bringing up the bundled "express" stack on Windows, four issues blocked a clean run. The first three are hard blockers for any Windows user; the fourth corrupts non‑ASCII user names. None of them are specific to a particular feature — they affect the stock self‑host setup.

---

## Issue 1 — `scripts/db-init-wrapper.sh` has CRLF line endings → database schema is never imported

**Symptom**
- The `postgres` container becomes `healthy`, but `worklenz_db` is **empty (0 tables / 0 functions)**.
- Everything that needs the DB fails afterwards.
- `docker logs worklenz-postgres` shows:
  ```
  /docker-entrypoint-initdb.d/00-init-wrapper.sh: cannot execute: required file not found
  ```

**Root cause**
On Windows, git checks out `*.sh` with CRLF line endings. The shebang becomes `#!/bin/bash\r`, so the Linux kernel looks for the interpreter `"/bin/bash\r"`, which does not exist → "required file not found". The init wrapper silently aborts and the schema import never runs.

**Fix**
Add a `.gitattributes` at the repo root forcing LF for shell scripts (and Dockerfiles, see Issue 2):
```gitattributes
*.sh        text eol=lf
Dockerfile  text eol=lf
```
This guarantees correct line endings regardless of the contributor's OS / git `core.autocrlf` setting.

---

## Issue 2 — `worklenz-frontend/Dockerfile` CRLF → frontend container crash-loops (exit 127)

**Symptom**
- `worklenz-frontend` is stuck `Restarting (127)`.
- `docker logs worklenz-frontend` shows:
  ```
  [FATAL tini (7)] exec /app/start.sh failed: No such file or directory
  ```

**Root cause**
The frontend Dockerfile generates `/app/start.sh` and `/app/env-config.sh` via heredocs (`COPY --chown=... <<'EOF' /app/start.sh`). When the **Dockerfile itself** has CRLF line endings, the generated `start.sh` gets a `\r` in its `#!/bin/sh` shebang → exec fails with "No such file or directory".
(Note: `worklenz-backend/Dockerfile` is also CRLF, but it does not generate shell scripts via heredoc, so it is unaffected — which is why the backend comes up fine and only the frontend crashes.)

**Fix**
Same `.gitattributes` rule (`Dockerfile text eol=lf`). Optionally also `*.Dockerfile` / `**/Dockerfile`.

---

## Issue 3 — `.env.example` localhost defaults cause a mixed-content / CSP block on login

**Symptom**
- The app loads at `https://localhost`, but login does nothing.
- Browser console:
  ```
  Connecting to 'http://localhost/csrf-token' violates the following Content Security Policy directive: "default-src 'self' https: data: blob: 'unsafe-inline'". ... The action has been blocked.
  Connecting to 'http://localhost/secure/login' violates ... Content Security Policy ...
  ```

**Root cause**
For `DOMAIN=localhost`, nginx auto-enables self-signed HTTPS, so the page is served over **https**. But `.env.example` ships:
```
VITE_API_URL=http://localhost
VITE_SOCKET_URL=ws://localhost
SOCKET_IO_CORS=http://localhost
FRONTEND_URL=http://localhost
```
The https page is not allowed to call the **http** API (mixed content + the CSP `default-src ... https:`), so `/csrf-token`, `/secure/verify`, `/secure/login` are all blocked and login fails silently.

**Fix (any of):**
- For localhost-with-SSL, default these to https/wss:
  ```
  VITE_API_URL=https://localhost
  VITE_SOCKET_URL=wss://localhost
  SOCKET_IO_CORS=https://localhost
  FRONTEND_URL=https://localhost
  ```
- Or clearly document in `.env.example` that when nginx SSL is on (the localhost default), these must be https/wss.
- Or make the frontend use protocol-relative / same-origin API URLs so it follows the page protocol automatically.

---

## Issue 4 — Non-ASCII (e.g. Chinese) user names render as mojibake

**Symptom**
- A user named `測試小明` appears as `æ¸¬è©¦å°æ` in the home greeting ("你好 …").
- The backend is fine: `GET /secure/verify` returns the correct `"name":"測試小明"`, and the DB stores it correctly. The corruption is purely client-side.

**Root cause (two contributing parts)**
1. **Asymmetric base64 encode/decode** in `worklenz-frontend/src/utils/session-helper.ts`:
   ```ts
   // write — UTF-8 safe:
   setItem(KEY, btoa(unescape(encodeURIComponent(JSON.stringify(user)))));
   // read — MISSING the inverse decode:
   JSON.parse(atob(getItem(KEY)));
   ```
   `setSession` encodes UTF-8 correctly, but `getUserSession` only does `atob(...)` and skips the matching `decodeURIComponent(escape(...))`. Multibyte UTF-8 is read back as Latin-1 → mojibake.
2. **`VITE_WORKLENZ_SESSION_ID` is not provided in the docker setup**, so `WORKLENZ_SESSION_ID` is `undefined` and the session is stored under the literal localStorage key `"undefined"`. It works, but it's fragile and confusing.

**Fix**
- Make decode symmetric in `getUserSession`:
  ```ts
  JSON.parse(decodeURIComponent(escape(atob(raw))));
  ```
  (Even better: use `TextDecoder`/`TextEncoder` for robust UTF-8 ⇄ base64.)
- Add `VITE_WORKLENZ_SESSION_ID` to `.env.example` and pass it to the `frontend` service in `docker-compose.yaml`.

---

## Suggested priority
1. **`.gitattributes` (Issues 1 & 2)** — without it, the stock stack does not start at all on Windows.
2. **`.env.example` https defaults / docs (Issue 3)** — without it, login is impossible on the default localhost SSL setup.
3. **session-helper UTF-8 decode (Issue 4)** — needed for any non-ASCII display name.
