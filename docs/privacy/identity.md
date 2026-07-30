# Visitor identity

How Tastatur tells one visitor from another without storing anything on their
device, and what that does and does not entitle us to claim.

## The construction

```
visitor_hash = HMAC-SHA256(salt, site_id ‖ 0x00 ‖ ip ‖ 0x00 ‖ user_agent)[0..15]
```

Implemented in `app/lib/ingest/identifier.rb`, the only file in the codebase that
touches an IP address.

Each decision in that one line:

**HMAC, not `SHA256(salt ‖ message)`.** The concatenation form is
length-extension weak: given a digest and the message length, an attacker can
compute the digest of an extended message without knowing the salt. Nothing in
our threat model obviously exploits that, but HMAC is the construction designed
for keyed hashing, costs the same, and removes the question.

**`site_id` in the message.** Without it, the same person produces the same
digest on every measured site, and one customer could test a hash against their
own traffic to learn whether a visitor had also visited another customer's site.
With it, the two digests are unrelated.

**Truncated to 128 bits.** Far beyond collision risk for one site-day, and
holding less of the digest means holding less of a re-identification handle.

**IPv6 reduced to its /64 prefix.** RFC 4941 privacy extensions rotate the
interface identifier (the low 64 bits) periodically and on every network join.
Hashing the full address would mint a brand-new "visitor" for the same person
several times a day and badly inflate the visitor count. The /64 is the network
they are on, which is the part that behaves like an IPv4 address. IPv4 is used
whole.

**Neither input is stored.** The IP and user-agent exist as local variables for
the duration of one method call. The user-agent is reduced to browser family,
major version, OS and one of desktop/mobile/tablet; the IP yields a two-letter
country code. Then both go out of scope. There is a spec asserting the resulting
value object exposes exactly `visitor_hash`, `session_hash` and `new_session` and
nothing containing either input, specifically so that a later well-meaning
addition breaks a test rather than the product's central promise.

## The salt

`app/lib/ingest/salt_store.rb`. Three properties are load-bearing.

### It lives only in Redis, never in PostgreSQL

Specifically, in a **dedicated** Redis instance started with:

```
redis-server --save "" --appendonly no --maxmemory-policy noeviction
```

`--save ""` disables RDB snapshots; `--appendonly no` disables the AOF, and no
volume is declared for it in either compose file.

One honest caveat, because it looks like a contradiction if you go checking. The
official `redis` image declares `VOLUME /data` in its own Dockerfile, so Docker
attaches an *anonymous* volume to that container whether or not the compose file
asks for one — `docker inspect` will show one mount. It stays empty, because
Redis is configured never to write a snapshot or an append log:

```console
$ docker compose exec redis-privacy sh -c 'ls -1 /data | wc -l'
0
```

So the guarantee rests on persistence being switched off, not on the absence of a
volume. That distinction is worth knowing: it means the thing to verify after
changing this service is that `/data` is still empty and a salt does not survive a
restart, rather than that no volume is listed.

This is the detail everything else rests on. The claim that stored analytics are
unlinkable depends on yesterday's salt being *gone* — and a salt written to an AOF
or an RDB snapshot is not gone. It is sitting in a file, very likely inside a
backup, next to the events it would de-anonymise. A point-in-time restore would
resurrect it and silently invalidate the claim.

`noeviction` means memory pressure fails loudly rather than silently evicting the
current salt and recounting every visitor.

If `REDIS_PRIVACY_URL` is unset the salt falls back to the main Redis and the app
logs a warning at boot, because that configuration trades away this guarantee.

### Exactly two salts exist per site at a time

Rotating to a single new salt would sever every session in flight and inflate the
visitor count every night. So the previous salt is kept, for 24 hours past the end
of the day it belonged to, purely so a session that began before the rollover can
still be recognised. Its Redis TTL is what destroys it; there is no archive.

The maximum life of any salt is therefore about 48 hours.

### Nothing can pin it

There is no setter, no seed, no fixture, and no way to supply a salt from
outside. A salt that could be pinned could be used to build a rainbow table over
the IPv4 space, which is only 4 billion entries.

We also explicitly **reject** deriving salts from a master key, e.g.
`HKDF(master_key, date)`. That is a common and fatal mistake: it makes every
historical salt regenerable forever, so nothing is ever actually destroyed.

### Rotation timing: each site's own midnight

Every site draws its own salt, and it rolls over at **00:00 in that site's
configured timezone**.

This used to be one instance-wide salt rotated by a nightly job at 04:07 server
time, and that was wrong in a way nothing surfaced. A day on the dashboard is a
day in the site's timezone — `Analytics::Period` builds every range in
`site.timezone` and the queries bucket with `time_bucket(..., site.timezone)`. So
for a site set to America/Los_Angeles the reporting day ran 07:00 UTC to 07:00
UTC, while the salt rotated at 04:07 UTC, which is 20:07 the previous *local*
evening — three hours inside the day being reported. One person browsing at 20:00
and again at 20:15 hashed to two different visitors and was **counted twice in the
same day, on the same report**. Only a site actually set to UTC was measured over
the window it was shown.

Aligning the rollover with the site's midnight makes the salt window and the
reporting day the same window, which is the only arrangement in which "unique
visitors today" means what it says.

There is no rotation job. The salt's Redis key names the site and the site-local
date it belongs to, so *which salt is current* is a question about the clock
rather than about whether a cron entry fired, and the retired key is destroyed by
its own TTL. That removes a failure mode nothing was watching: a skipped or wedged
job left yesterday's salt live indefinitely, and the symptom of the product
quietly ceasing to be anonymous was nothing at all. It also serves zones a cron
schedule cannot express — Asia/Kolkata (+05:30), Asia/Kathmandu (+05:45) and
Pacific/Chatham (+12:45) have local midnights no hourly job can hit.

**The date names the key; it does not produce the secret.** The value stored under
that name is `SecureRandom` and is never recomputed from anything, which is the
whole difference between this and the master-key derivation rejected above.
`spec/privacy_invariants_spec.rb` holds that line.

Rotation is verified by spec to satisfy three properties at once, which naive
implementations get wrong:

- the visitor hash **does** change across the rollover (yesterday becomes
  unlinkable),
- an in-flight session is **carried across** it, so nobody is counted twice and
  no visit is cut in half, and
- two sites in different timezones roll over at **different moments**, each at its
  own midnight

## Sessions

A session is "the same visitor with no gap longer than 30 minutes". That is a
sliding window, which is exactly what a Redis key with a TTL is: the key holds
the session id, `GETEX` reads it and pushes its expiry back in one round trip, and
if the visitor goes quiet for longer than the timeout the key evaporates and the
next event opens a fresh session.

Redis rather than a database table because this runs on every single ingest
request; a `SELECT`-then-`UPDATE` against PostgreSQL per pageview would be several
times more expensive and would contend on the same rows under load.

The state is intentionally disposable. If the privacy Redis is lost, in-flight
sessions restart: visits get split and the visit count ticks up slightly for one
timeout window. That is an acceptable failure mode for analytics and a much
better one than persisting visitor state to disk.

## What this entitles us to say

**While a salt is live, data derived from it is pseudonymous, not anonymous.**
The salt exists, so the mapping from (IP, user-agent) to hash is computable by
whoever holds it. Calling that "fully anonymous" would be false.

**Once the salt is destroyed, the link cannot be rebuilt.** Not by an attacker
with the database, and not by us. At that point the events are unlinkable to any
future observation of the same person.

**An IP address is personal data.** Under GDPR (*Breyer*, C-582/14) and expressly
under the CCPA. We receive one on every request. Saying "we collect no personal
data" would be false, and the privacy page says so directly.

The honest chain is:

1. collection and in-memory processing of IP + user-agent is processing of
   personal data, on the basis of the site owner's legitimate interest in
   understanding aggregate usage (GDPR Art.6(1)(f));
2. the persisted data is pseudonymous while the salt lives;
3. after salt destruction and k-anonymisation, the derived statistics fall
   outside GDPR.

For the phrases this project refuses to use, see [claims.md](claims.md).

## A known limitation, stated plainly

Two different people behind the same NAT with the same browser and OS version
hash to the same visitor. Conversely, one person switching from wifi to cellular
mid-visit becomes two visitors. Both are inherent to identifying by network and
device profile rather than by a stored identifier, and both are the price of not
storing one. The dashboard's numbers should be read as a good estimate of
aggregate behaviour, not as a census.

## Operator controls

```bash
rails tastatur:privacy:purge_salts   # destroy both salts immediately
```

Every stored visitor hash becomes permanently unlinkable to any future
observation. Offered because an operator responding to an incident should be able
to sever that link without waiting for a cron job.
