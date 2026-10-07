# Decisions

Accepted decisions for this Ruby on Rails API. One heading per decision: context, decision, consequence. Git history is the changelog. When a choice changes, replace the section. Do not append an amendment log, and do not store secrets here.

## SQL through pg against v1_* views

**Context.** The public catalog is PostgreSQL `v1_*` views in the CMS database. Ash resource tables are the CMS write model.

**Decision.** Query only those views with the `pg` gem from `Catalog`. Do not add Active Record models of Ash tables, and do not `SELECT` from the Ash base tables.

**Consequence.** This repo has no schema migrations and no Active Record connection pool. The connection string is `DATABASE_URL`.

## Background registration that no-ops when the CMS is down

**Context.** The Phoenix site keeps at most one language API warm. A hung or absent CMS must not stop this process from serving traffic.

**Decision.** Register once, after Puma boots, on a background thread (`Catalog.register_in_background` from `after_booted`). No heartbeat. If `CAROLINA_URL` or `POLYGLOT_REGISTER_TOKEN` is unset, or the POST fails, log and keep serving. Skip registration when `Rails.env.test?`.

**Consequence.** `/health` does not wait on the CMS. The register POST keeps its open and read timeouts on that background thread.

## pg pool sized to RAILS_MAX_THREADS

**Context.** Puma serves each request on a thread. The Phoenix site fetches speakers and sponsors in parallel, so concurrent requests each need their own Postgres connection.

**Decision.** Size the `pg` pool to `RAILS_MAX_THREADS` (default 3), the same value `config/puma.rb` uses for its thread count.

**Consequence.** Raising `RAILS_MAX_THREADS` raises the pool. Do not add a second pool size that can drift below the thread count.

## Compiler-free runtime image with bootsnap and YJIT

**Context.** Native gems need a C toolchain to compile. The production VM should not carry that toolchain, and boot should stay short.

**Decision.** Use a multi-stage `Dockerfile`: compile gems and run `bootsnap precompile` in the build stage, then copy the app into `ruby:4.0-slim` with `libpq5` only. Enable YJIT with `RUBY_YJIT_ENABLE=1` in the image and again in `config/boot.rb` when `RAILS_ENV=production`.

**Consequence.** The runtime image has no C compiler. A gem that needs a native extension must rebuild the build stage. Production boots from the bootsnap cache with YJIT on.
