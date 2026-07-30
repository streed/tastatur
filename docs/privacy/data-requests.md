# Data requests

How subject access, erasure and objection work when the stored data contains no
identifier that resolves to a person.

## Who is responsible for what

| | Controller | Processor |
|---|---|---|
| Measurement data (events from a site's visitors) | **the site owner** | Tastatur |
| Account data (email, team membership, billing) | **Tastatur** | — |

A visitor's request about a specific site belongs to that site's operator: they
decide what is collected, for how long, and why. Tastatur's job is to make it
possible for them to answer.

## Subject access

The honest answer to "what do you have on me?" is "nothing we can link to you",
and GDPR Art.11(1) covers exactly that: where a controller can demonstrate it is
not in a position to identify a data subject, the rights in Arts.15–20 do not
apply.

Requests about a specific site go to that site's operator, who is the controller
and who can erase the site's entire history immediately. That is the whole of the
answer, and there is deliberately no self-service lookup beside it.

### Why there is no self-service lookup

There used to be one. `/data-request` recomputed the visitor HMAC from the live
connection and listed every matching row, on the reasoning that the source address
comes from a completed TCP handshake and so cannot be pointed at anyone else.

**That reasoning was wrong, and the page was removed on 2026-07-30.** The identity
is `HMAC(salt, site_id ‖ ip ‖ user_agent)`, and only the address comes from the
connection — the user-agent is a request header the caller sets to anything it
likes. So the lookup was never keyed on something the caller had to prove; it was
keyed on an address they shared with their whole network plus a string they could
guess.

Both halves are weak in the same direction. Sharing a public IPv4 address is the
normal case (household NAT, office, café, hotel, VPN exit, mobile CGNAT), and
`Ingest::Identifier` masks IPv6 to the /64, which is the subnet rather than the
device. Meanwhile user-agent strings have been *deliberately* reduced by browser
vendors — Chrome freezes the minor version at `0.0.0` — so the candidate set is
small enough to walk through by hand. Anyone on the same network could therefore
retrieve up to 500 of a neighbour's rows: site domain, full path, timestamp,
country, browser, OS and device type, across every site on the instance.

Reproduced against the real endpoint before removal: same source address, victim's
user-agent supplied by the attacker, victim's page views returned.

No configuration of that design is safe. Dropping the user-agent from the lookup
shows everyone on an address each other's rows, which is worse; keeping it leaves
a guessable discriminator. On a shared address there is nothing unguessable
separating two people, because the product deliberately holds no cookie or token
that could serve as one — the same property that makes the data unlinkable in the
first place is what makes a self-service lookup impossible to do safely.

The retention claim consequently has to be *read* rather than demonstrated, which
is a genuine loss. `docs/privacy/identity.md` is the technical account, and the
salt handling in `app/lib/ingest/salt_store.rb` is the authority.

## Erasure

For measurement data, erasure is per-site and immediate:

**Site settings → Delete this site.**

`Sites::Delete` removes the site and issues a `DELETE` over every event ever
recorded for it, in one transaction, and clears the ingest token cache so
collection stops at once rather than at the end of the cache TTL. There is no
soft delete and no recovery.

It then reconciles the continuous aggregates over the window that site occupied.
This is not bookkeeping, it is part of the erasure: deleting raw rows does **not**
remove them from an aggregate, and the scheduled refresh policies only look back
three to ten days, so without this step the rollups would keep reporting the
deleted events permanently, including `visitor_days`, which holds visitor hashes.
Raw deletion is immediate and synchronous; the rollup reconciliation runs as a job
straight afterwards and normally completes in seconds. Detail and the measurement
that exposed it are in
[../architecture/aggregates.md](../architecture/aggregates.md#deleting-raw-rows-does-not-delete-aggregate-rows).

We cannot erase "all data about individual X" on request, because no query can
identify which rows belong to them once the salt is gone. That is a consequence of
the design rather than a limitation of the implementation, and it is the same
property that makes the data unlinkable in the first place.

An instance-wide option exists for incident response:

```bash
rails tastatur:privacy:purge_salts
```

which destroys both live salts, making every stored hash permanently unlinkable
to any future observation.

## Objection and opt-out

Tastatur honours **Do Not Track** and **Global Privacy Control** by default, both
in the tracker and again server-side — the server-side check matters because the
ingest endpoint is a public HTTP API that an older cached copy of the script, or
the `<noscript>` pixel, might call without checking a header.

When honoured, nothing is hashed, geolocated or stored. Only a coarse counter is
incremented, per site per hour, so a site owner can see that some requests opted
out without any visitor-level record existing.

There is deliberately **no per-person opt-out flag**, because storing one would
mean keeping a durable identifier for precisely the people who asked us not to.
A browser header is the right mechanism here.

## Retention

| Data | Default | Configurable |
|---|---|---|
| Visitor salt | ~24h live, destroyed within 48h | no |
| Session map | 30 minutes of inactivity | `SESSION_TIMEOUT_MINUTES` |
| Raw events | 12 months | per account, 3 to 25 months |
| `visitor_days`, `session_days` | follows raw events | yes |
| `events_by_hour` | 5 years | holds no identifiers |

Aggregates that contain no visitor-level rows are kept longer than raw events;
those that do (`visitor_days`, `session_days`) follow the raw-event window,
because keeping a visitor-grain table for five years would undercut the retention
promise made about the events table itself.

## Answering a DPO's questionnaire

The three documents to hand over:

- `/privacy` — what is collected, what is discarded, and the honest
  pseudonymous-versus-unlinkable distinction
- `/dpa` — Art.28 processor terms, including the operating commitments enforced
  in code (no cross-account pooling, no reuse for our own purposes)
- [claims.md](claims.md) — the language this project refuses to use, which is
  usually the fastest way to establish that nobody is overselling

For the technical detail behind the identifier, [identity.md](identity.md).
