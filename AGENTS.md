# carolina-codes-rails

Read-only v1 polyglot HTTP API. A Carolina Code Conference Elixir site can rotate onto this process. This repository is a finished Rails API and its own git remote (`github.com/brightball/carolina-codes-rails`). It is not the forkable starter and it is not the Phoenix CMS.

The HTTP contract is the CMS OpenAPI: `priv/api/openapi.yaml` and `priv/api/AGENTS.md` in `github.com/brightball/carolina-codes`. This tree does not ship `openapi.yaml`. Do not implement Ash JSON:API (`application/vnd.api+json`). Siblings speak ordinary JSON over the v1 REST + SQL-view contract.

You do not need a checkout of the Elixir CMS or the Sinatra sibling to run this API. Registration is best-effort: if `CAROLINA_URL` is unset or the CMS is down, skip the register call and still serve HTTP.

Before an architectural change, read `DECISIONS.md` and `MEMORY.md`. Record a durable choice in `DECISIONS.md` (replace the section; git history is the changelog). Record a non-obvious correction in `MEMORY.md`. Do not copy secrets into either file.

## Purpose

The Phoenix app (`Carolina.Polyglot`) keeps at most one language API warm and reads speakers and sponsors from it. With no APIs registered, it falls back to Ash. This process must:

1. Query PostgreSQL `v1_*` views with the `pg` gem. Never query Ash resource tables, and never map them with Active Record.
2. Expose the routes in the CMS OpenAPI.
3. Register once on boot with the Elixir site (no heartbeat). If the site is not running, log and continue.

## Environment

| Variable | Example | Role |
| --- | --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@127.0.0.1:5432/carolina_dev` | `v1_*` views in the CMS database (Postgres 16) |
| `CAROLINA_URL` | `http://127.0.0.1:4000` | Elixir site (optional; registration no-ops if unset or the POST fails) |
| `POLYGLOT_REGISTER_TOKEN` | `dev` | Bearer token for register |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:4018` | URL Elixir will call |
| `PORT` | `4018` | Listen port (the image defaults to `8080`) |
| `RAILS_MAX_THREADS` | `3` | Puma thread count and the `pg` pool size |

## SQL views (query these)

`v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_sponsors`.

The views live in the CMS database. This repo does not ship `db/*.sql` or a Compose Postgres. Do not `SELECT` from `speakers`, `organizations`, `talks`, or other Ash base tables. The views are the API.

Year-scoped speaker rows include `languages` and `topics`. Year-scoped sponsor rows include `tier` and `blurb`.

## Required HTTP routes

Wrap list bodies as `{ "data": [ ... ] }`. An unknown slug returns 404. No writes.

- `GET /health` — `{ "status": "ok" }`. Does not touch the database.
- `GET /` — identity (`language`, `framework`, `api_version`, endpoints)
- `GET /v1/years`
- `GET /v1/speakers` and `GET /v1/speakers?year=2025`
- `GET /v1/speakers/{slug}` and `GET /v1/speakers/{year}/{slug}`
- `GET /v1/sponsors` and `GET /v1/sponsors?year=2025`
- `GET /v1/sponsors/{slug}` and `GET /v1/sponsors/{year}/{slug}`

`photo_path` and `logo_path` are web paths. Return the path. This API does not serve image bytes.

## Register on boot (once)

`POST {CAROLINA_URL}/internal/api-endpoints/register`

```
Authorization: Bearer {POLYGLOT_REGISTER_TOKEN}
Content-Type: application/json
```

Body fields: `language`, `language_version`, `api_version`, `framework`, `created_year`, `base_url` (`PUBLIC_BASE_URL`), `schema_version` (1), `endpoints`.

Do not heartbeat. If `CAROLINA_URL` or the token is empty, or the POST fails, log and keep serving.

Registration runs in a background thread from Puma `after_booted`, after the accept loop is up, so a hung CMS cannot block `/health`. The test environment skips it.

## Commands

```bash
mise install
bundle install
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4018 \
PORT=4018 \
bin/rails server
```

```bash
bin/rails test
bin/ci                       # setup + tests, Brakeman, bundler-audit, gitleaks, RuboCop
pre-commit run --all-files
```

Handler tests that set `Catalog.query_fn` do not need Postgres. Live HTTP against the views needs the CMS database.

## Layout this repo ships

| Path | Role |
| --- | --- |
| `app/models/catalog.rb` | `pg` queries against `v1_*` views, pool, and one-shot registration |
| `app/controllers/` | JSON routes |
| `config/puma.rb` | Thread count, dual-stack bind, background register after boot |
| `config/boot.rb` | bootsnap, and YJIT when `RAILS_ENV=production` |
| `Dockerfile` | Build with a C toolchain, `bootsnap precompile`, then a runtime image with no compiler and `RUBY_YJIT_ENABLE=1` |
| `bin/ci` | Five quality checks |
| `DECISIONS.md` | Accepted decisions |
| `MEMORY.md` | Non-obvious corrections for agents |

The starter paths `openapi.yaml`, `db/*.sql`, `src/`, `images/`, and Compose Postgres are not in this tree. Do not add them back to chase the starter layout.

## Checklist

- Required paths return example-shaped JSON (404 on an unknown slug)
- `?year=` rows include `languages` / `topics` (speakers) and `tier` (sponsors)
- Register runs once after Puma boots and still serves if registration fails
- `/health` does not query the database
- No writes; no Ash table names; no Active Record models of those tables
- The `pg` pool size matches `RAILS_MAX_THREADS`
