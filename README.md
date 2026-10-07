# carolina-codes-rails

Read-only v1 polyglot API for Carolina Code Conference. **Ruby 4.0.6** (`.ruby-version`) and **Rails 8.1.3.1** (`Gemfile.lock`), API-only, on Puma. Distinct from `../ruby` (Sinatra on :4001).

Boot caches work with **bootsnap** (`config/boot.rb`, and `bootsnap precompile` in the image build). Production enables **YJIT** (`RUBY_YJIT_ENABLE` on the runtime image and in `config/boot.rb`). The runtime image ships without a C toolchain.

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

Quality gates (tests, Brakeman SAST, bundler-audit, gitleaks, RuboCop). Local precommit and Gitea Actions run the same five commands as separate checks:

```bash
mise install
pre-commit run --all-files   # or: git config core.hooksPath .githooks
bin/ci                       # setup + the five checks
mise run secrets             # gitleaks git --verbose
```

Emergency skip: `SKIP=rails-test,brakeman,bundler-audit,gitleaks,rubocop git commit`. Gitea prepares the workspace once, then runs one job per check in `.gitea/workflows/precommit.yml`.
