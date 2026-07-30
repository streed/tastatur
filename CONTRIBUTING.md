# Contributing to Tastatur

Thanks for considering it. This document is mostly about the handful of things in
this codebase that are unusual, because those are where a well-meaning change is
most likely to break something silently.

Tastatur is developed and maintained by [Reedster LLC](https://reedster.llc) and
licensed under the [AGPL-3.0](LICENSE).

## Getting set up

```bash
git clone https://github.com/streed/tastatur.git
cd tastatur
docker compose up
```

Open <http://localhost:3000> and sign in as `user@example.com` / `password`.
Fill the dashboard with plausible traffic:

```bash
docker compose exec web bin/rails tastatur:demo_data DAYS=90
```

Run the suite:

```bash
bin/dspec                    # everything, in the container, against the test DB
bin/dspec spec/lib           # a subset
bin/dspec spec/x_spec.rb:42  # one example
```

The whole suite runs in about fifteen seconds. Please keep it that way; a slow
suite stops being run.

## Read this before your first change

Two documents, and they will save you more time than they take:

- **[CLAUDE.md](CLAUDE.md)** — the architectural rules, including a section of
  "things that look like bugs but are deliberate". Several of them were learned
  the hard way and are load-bearing.
- **[docs/development.md](docs/development.md)** — the footguns, each with the
  symptom it produces.

The short version of what bites people:

**There is no `schema.rb`, deliberately.** A `pg_dump` of a TimescaleDB database
does not emit `create_hypertable`, and a continuous aggregate dumps as a plain
`CREATE VIEW`. Loading such a dump gives you ordinary tables and unmaterialised
views — a database that works but is quietly wrong, with nothing raising. Do not
add a schema file back. Migrations are the only source of truth.

**Deleting raw events does not delete aggregate rows.** The refresh policies only
look back three to ten days, so an older invalidation is never processed. Any new
code path that bulk-deletes historical events must call
`Analytics::ReconcileAggregates`, or reports will keep showing erased data.

**Distinct counts must never be summed across aggregate buckets.** Adding 24
hourly unique-visitor counts does not give you the day's uniques; it counts every
returning visitor once per active hour. Measured on the demo dataset: 1,200
instead of 40.

**Migrations that create a continuous aggregate need `disable_ddl_transaction!`**,
and must refresh *before* adding the refresh policy or the two collide.

## The privacy invariants

These are not style preferences. Each one backs a specific claim on `/privacy`,
and each has a spec that will fail if you break it.

- **The IP address and user-agent are never persisted.** They exist as local
  variables inside `Ingest::Identifier#call` and nowhere else. If you are about to
  add a column or a log line containing either, that is the change that breaks the
  product's central promise.
- **The rotating salt lives only in the non-persistent Redis.** A salt written to
  an AOF or RDB file is not destroyed; it sits in a backup next to the events it
  would de-anonymise.
- **Never derive salts from a master key.** `HKDF(master, date)` makes every
  historical salt regenerable forever, so nothing is ever actually destroyed.
- **Personal data is stripped from paths, not just query strings.** Customer sites
  put emails and tokens in path segments constantly.
- **k-anonymity includes complementary suppression.** Hiding one small row
  protects nothing when its value is `total − Σvisible`.

## Claims discipline

If your change touches user-facing copy, docs, or the README, check it against
**[docs/privacy/claims.md](docs/privacy/claims.md)**. That file lists the phrases
this project will not use and why — in both directions. Over-warning is as much a
credibility problem as over-promising, and a spec enforces the banned list.

The rule of thumb: state measured numbers, name the specific property rather than
saying "privacy-friendly", and say plainly what the software cannot do.

## Conventions

Summarised from [CLAUDE.md](CLAUDE.md):

| Layer | Where | Contract |
|---|---|---|
| Services | `app/services/` | Subclass `ApplicationService`, one public `call`, return `Success`/`Failure` |
| Contracts | `app/contracts/` | `Dry::Validation::Contract` for anything crossing a boundary |
| Value objects | `app/values/` | `Dry::Struct`. No untyped hashes across layers, no `OpenStruct` |
| Infrastructure | `app/lib/` | Collaborators that are neither model nor service |
| Models | `app/models/` | Associations, scopes, validations, trivial helpers. No orchestration |
| Jobs | `app/jobs/` | Thin wrappers that call a service |
| Policies | `app/policies/` | Pundit, always. Receives an `AuthorizationContext`, not a bare user |

Forms use `TastaturFormBuilder` — `f.field`, `f.error_summary`, `f.actions`. Do
not hand-roll `<input>` markup; if your form has no ActiveRecord model, give it an
`ActiveModel` form object (see `MemberInvitation`).

No npm, no build step beyond Tailwind. Charts are server-rendered inline SVG and
interactivity is Stimulus. A privacy tool should not ask its users to load a
bundle.

## Tests

Write the spec that would have caught the bug. Several specs in this repo exist
because something was broken in a way that looked like working software, and each
of those carries a comment explaining the symptom — please do the same.

Prefer request specs over controller specs for anything user-facing. Two real bugs
here (funnel steps not saving, every generated link 404ing) would have passed a
model or controller spec and were only caught by driving the actual HTTP path.

Tags that matter:

- `:continuous_aggregate` — the example needs materialised aggregate data, so it
  drops the transactional fixture and truncates instead.
  `refresh_continuous_aggregate` cannot run inside a transaction.
- `:throttled` — the example exercises a rate limit. Rack::Attack is disabled by
  default in specs because its counters now live in Redis and persist between
  examples.

## Pull requests

1. Branch from `main`.
2. Make sure `bin/dspec` passes and `bin/brakeman --no-pager -i config/brakeman.ignore`
   reports nothing.
3. Explain **why**, not just what. A diff shows what changed; the reason it
   changed is the part that gets lost.
4. If you fixed something subtle, say what the symptom was. That sentence is
   worth more than the patch to whoever reads it in a year.

Small, focused PRs get reviewed faster. If you are planning something large, open
an issue first so we can agree on the shape before you spend the time.

## Reporting a security issue

Do not open a public issue. See [SECURITY.md](SECURITY.md).

## Licence

By contributing you agree that your contribution is licensed under the AGPL-3.0,
the same terms as the project.
