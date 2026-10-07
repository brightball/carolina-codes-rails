# Agent memory

Corrections that are easy to get wrong in this Rails API. The operational contract is `AGENTS.md`. Accepted choices are `DECISIONS.md`. Add a bullet when a correction is non-obvious. Do not copy those files here, and do not store secrets, credentials, or tokens beyond the public local examples already in the README.

- This repository is its own git remote. Do not fold the tree into the Phoenix CMS remote (`github.com/brightball/carolina-codes`).
- Do not assume `../elixir` or the Sinatra app at `../ruby` is on disk. Cloud agents often have only this remote. The Sinatra sibling is a different codebase and listens on port 4001.
- Tests that set `Catalog.query_fn` use a fake catalog and do not need Postgres. Do not start a database for those.
- Do not follow starter paths this tree does not contain (`openapi.yaml`, `db/*.sql`, `src/`, `images/`, Compose Postgres). The views are Postgres 16 objects in the CMS database. The HTTP contract is the CMS OpenAPI, not a file here.
- `GET /` reports `framework: "Rails"`. This process is not the Sinatra API.
- Register from Puma `after_booted` via `Catalog.register_in_background`. An initializer that runs before the accept loop can block `/health` on a hung CMS.
- Leave Puma at its default worker count. The production VM is small; do not raise `WEB_CONCURRENCY` to chase throughput.
- `config/master.key` is gitignored. `config/credentials.yml.enc` is ciphertext. Do not decrypt credentials into docs, commits, or this file.
