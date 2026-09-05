# carolina-codes-rails

Read-only v1 polyglot API for Carolina Code Conference. **Ruby 4.0.6** + **Rails 8.1.3.1** (API-only, Puma). Distinct from `../ruby` (Sinatra on :4001).

Queries PostgreSQL `v1_*` views. Registers with Elixir once on boot.

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

`GET /` reports `language: "Ruby"` and `framework: "Rails"`. `GET /health` returns `{"status":"ok"}` without touching Postgres.

```bash
bin/rails test
```
