# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

This is a two-app monorepo **with no root `package.json` and no workspace tooling**. The two apps are fully independent npm projects — always `cd` into the right one before running `npm` commands.

- `worklenz-backend/` — Express.js + TypeScript API (REST + Socket.io), PostgreSQL, native SQL (no ORM).
- `worklenz-frontend/` — React 18 + TypeScript SPA built with Vite, Redux Toolkit, Ant Design + Tailwind.

## Commands

### Backend (`cd worklenz-backend`)

| Task | Command |
|------|---------|
| Install | `npm install` |
| Dev (build watch + auto-restart server) | `npm run dev:all` |
| Build (dev) | `npm run build:dev` |
| Build (prod, minify + compress) | `npm run build:prod` |
| Run all tests | `npm test` |
| Watch tests | `npm run test:watch` |
| Run a single test file | `npx jest src/tests/constants.spec.ts` |
| Run tests by name | `npx jest -t "partial test name"` |
| Lint (no npm script — run directly) | `npx eslint src` |
| Scaffold a controller + router (auto-registers route) | `node ./cli/generate-controller "feature name"` |
| Scaffold a validator middleware | `node ./cli/generate-validator "feature name"` |

Compiled output goes to `build/` and is **git-ignored** — never commit it. The server runs from `build/bin/www.js`.

### Frontend (`cd worklenz-frontend`)

| Task | Command |
|------|---------|
| Install | `npm install` |
| Dev server (port **5173**) | `npm run dev` |
| Build (runs `copy-tinymce.js` prebuild) | `npm run build` |
| Run all tests (watch) | `npm run test` |
| Run tests once | `npm run test:run` |
| Coverage | `npm run test:coverage` |
| Run a single test file | `npx vitest run src/pages/auth/__tests__/LoginPage.test.tsx` |
| Run tests by name | `npx vitest run -t "partial test name"` |
| Format (no lint script; Prettier only) | `npm run format` |

## Local Dev Topology (easy to get wrong)

Manual (non-Docker) development runs **two servers on two ports**, connected by CORS — there is **no Vite dev proxy**:

- Frontend dev server: `http://localhost:5173`
- Backend API: `http://localhost:3000` (backend `.env` `PORT=3000`)
- The frontend targets the backend via `VITE_API_URL` / `VITE_SOCKET_URL` (see `worklenz-frontend/.env.development`, pointing at `:3000`).
- Gotcha: `worklenz-backend/.env.template` ships `FRONTEND_URL` and `SOCKET_IO_CORS` set to `:5000` (the Docker/nginx port). For manual dev with the Vite server, the backend's CORS origins must include `http://localhost:5173`, or browser requests/sockets will be blocked.

Docker Compose (`docker compose --profile express up -d`, from repo root) puts everything behind nginx, served at `https://localhost` / `http://localhost`. See `DOCKER_SETUP.md`.

## Backend Architecture

**Entry & startup:** `src/bin/www.ts` (imports `./config` first to load dotenv) → boots the Express app from `src/app.ts`, then attaches Socket.io, Redis, cron jobs, and PostgreSQL LISTEN/NOTIFY listeners. Middleware wiring (Helmet, CORS, session, Passport, CSRF, rate limiting, route mounting) all lives in `src/app.ts`.

**Data access — native SQL, no ORM.** A single `pg` pool is exported from `src/config/db.ts`; everything does `db.query(sql, [params])` with `$1, $2` placeholders. A large amount of business logic lives in **PostgreSQL functions** (e.g. `SELECT create_project($1)`), not in TypeScript. Use `src/shared/sql-helpers.ts` (`SqlHelper`) to build IN-clauses / pagination safely. Never string-interpolate values into SQL.

**Database schema** is plain SQL files, not migrations-as-code:
- Initial setup: run `database/sql/*.sql` in the order documented in `worklenz-backend/README.md` (`0_extensions` → `1_tables` → `indexes` → `4_functions` → `triggers` → `3_views` → `2_dml` → `5_database_user`).
- Incremental changes: hand-written SQL under `database/migrations/`, applied manually in filename order and deleted once released (see that folder's `README.md`). There is no automatic migration runner.

**Controllers** (`src/controllers/`) follow a fixed pattern — the `generate-controller` scaffold is the source of truth:
- A class extending `WorklenzControllerBase` with **all-`static` async methods** (`create`/`get`/`getById`/`update`/`deleteById`).
- Every public method is wrapped with the `@HandleExceptions()` decorator (`src/decorators/handle-exceptions.ts`), which centralizes try/catch and maps PostgreSQL constraint errors to messages (pass `raisedExceptions` to customize).
- Methods return `new ServerResponse(done: boolean, body, message?)` (`src/models/server-response.ts`). Note: failures are returned as `ServerResponse(false, ...)` with HTTP **200**, not an error status.
- Pagination params come via `WorklenzControllerBase.toPaginationOptions()`.

**Routes** (`src/routes/apis/<feature>-api-router.ts`, aggregated in `src/routes/apis/index.ts`): stack validators before the controller and wrap each handler with `safeControllerFunction(...)`. Auth tiers are mounted in `src/app.ts`: everything under `/api/v1` requires login; `/public` is open. Role checks are validator middlewares in `src/middlewares/validators/` (e.g. `team-owner-or-admin-validator`, `project-manager-validator`).

**Authentication:** Passport (`src/passport/`) with local + Google OAuth strategies, backed by `express-session` stored in PostgreSQL via `connect-pg-simple` (`pg_sessions` table). `req.user` carries `id`, `team_id`, `team_member_id`. Mobile clients pass session via headers instead of cookies. CSRF (`csrf-sync`) is enabled with `/api`, `/public`, `/secure`, `/webhook` excluded.

**Socket.io** (`src/socket.io/`): event names are an enum in `events.ts`; each event has one handler file in `commands/`; all handlers are registered in `index.ts`'s `register()`. Handlers parse a JSON string payload, resolve the user via `getLoggedInUserIdFromSocket()`, call a DB function, then emit/broadcast and log activity. Use `src/shared/io.ts` (`IO.emitByUserId` / `emitByTeamMemberId`) to emit from outside a socket handler.

**Conventions:** no TypeScript path aliases — use relative imports (`../config/db`). ESLint (`.eslintrc.json`) enforces double quotes, semicolons, `prefer-const`, `no-underscore-dangle`, `no-param-reassign`, and `plugin:security`. Cross-cutting services live in `src/services/` (`activity-logging.service.ts`, `notifications/notifications.service.ts`) and are called from both controllers and socket handlers.

## Frontend Architecture

**Entry & routing:** `src/index.tsx` → `src/App.tsx`. Routes are composed in `src/app/routes/index.tsx` from per-area files (`auth-routes`, `main-routes`, `settings-routes`, etc.), all lazy-loaded with `React.lazy` + `Suspense`. Route protection is via guard components: `AuthGuard`, `AdminGuard`, `LicenseExpiryGuard`, `SetupGuard`.

**State — Redux Toolkit.** Store is `src/app/store.ts`; feature state lives under `src/features/<feature>/` as slices. Use the typed `useAppDispatch` / `useAppSelector` hooks. `serializableCheck` is disabled in store config.

**Data fetching is split between two mechanisms — match the surrounding code:**
- **RTK Query** services (e.g. `src/api/projects/projects.v1.api.service.ts`, plus home-page and user-activity APIs) — their middleware is registered in the store; use tag invalidation for refetch.
- **Axios** via `src/api/api-client.ts` for everything else. Its interceptors auto-attach the CSRF token, refresh it on 403, redirect to `/auth/login` on 401, and surface success/error toasts based on the response's `done` flag. `withCredentials: true`.

**UI:** Ant Design v5 + Tailwind coexist. Import all antd components from the central `src/shared/antd-imports.ts` barrel (not directly from `antd`) — this keeps a single React context and helps tree-shaking. Theme/dark-mode is handled in `src/features/theme/ThemeWrapper.tsx` (antd algorithm + a `dark`/`light` class + CSS variables).

**Socket.io client** is provided through React Context in `src/socket/socketContext.tsx` (consume via `SocketContext` or `useSocketService`); a singleton guards against StrictMode double-connects. Event-name constants are in `src/shared/socket-events.ts`.

**i18n:** i18next (`src/i18n.ts`) loading JSON from `public/locales/<lng>/<ns>.json`; current language is mirrored in a Redux slice.

**Conventions:** absolute imports via aliases (`@/`, `@components/`, `@features/`, … — defined in both `tsconfig.json` and `vite.config.mts`), never deep relative paths. Prettier (`.prettierrc`): single quotes, `printWidth` 100, `arrowParens: avoid`. Env vars must be `VITE_`-prefixed and also support runtime override via `window.VITE_*` (resolved in `src/config/env.ts`).

## Testing Notes

- Backend uses **Jest with `automock: true`** (`jest.config.js`) — every imported module is auto-mocked by default, so tests must `jest.unmock()` what they actually exercise. Test files are `src/tests/*.spec.ts`; `.spec.ts` is excluded from the TS build.
- Frontend uses **Vitest** (`vitest.config.ts`, jsdom, globals on, setup in `src/test/setup.ts`). The legacy `jest.config.js` in the frontend is unused. Tests live in `__tests__/` folders as `*.test.tsx`.
