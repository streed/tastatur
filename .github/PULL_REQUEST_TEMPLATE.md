<!--
Thanks for sending this. Delete whatever does not apply — a small fix does not need
every heading filled in, and a mostly-empty template is worse than a short paragraph.
-->

## What this changes

## Why

<!--
The part that gets lost. A diff shows what changed; the reason is what someone needs
in a year. If you fixed a bug, say what the symptom looked like — that sentence is
often worth more than the patch.
-->

## How it was verified

<!-- e.g. "bin/dspec", "added a spec that fails without the fix", "measured against
the demo dataset and the numbers now match raw SQL". "Ran the app and clicked around"
is a legitimate answer; saying so is better than implying more. -->

---

## Checks

- [ ] `bin/dspec` passes
- [ ] `bin/rubocop` is clean
- [ ] `bin/brakeman --no-pager` reports nothing new
- [ ] A spec covers this, or there is a reason in the description why not

## Does this touch stored data?

<!-- Skip this section entirely if not. If any box is checked, please say more,
because these are the changes that need the most care. -->

- [ ] Adds, removes, or changes a persisted column
- [ ] Changes what is derived from a visitor's IP address or user-agent
- [ ] Touches the salt, its rotation, or where it is stored
- [ ] Changes a k-anonymity threshold or how suppression is applied
- [ ] Changes retention, or anything that deletes historical events

If you checked the last one: bulk deletion must call
`Analytics::ReconcileAggregates`, or erased data keeps appearing in reports. The
refresh policies only look back a few days, so an older invalidation is never
processed on its own.

## Does this change a claim?

- [ ] Changes user-facing copy, the README, or anything in `docs/`

If so, it has been checked against [docs/privacy/claims.md](../docs/privacy/claims.md),
which lists the phrases this project will not use — in both directions. Overstating
what the software protects and overstating what a user must worry about are both
credibility problems, and a spec enforces the banned list.

## Migrations

<!-- Delete if there are none. -->

- [ ] Uses `disable_ddl_transaction!` if it creates a continuous aggregate, and
      refreshes *before* adding the refresh policy
- [ ] Runs against a cold database as well as an existing one
- [ ] No `schema.rb` was added back

The last one is not a style preference. `pg_dump` emits neither `create_hypertable`
nor the `timescaledb.continuous` flag, so a loaded schema silently produces ordinary
tables and unmaterialised views — a database that works and is quietly wrong, with
nothing raising. See [CONTRIBUTING.md](../CONTRIBUTING.md).
