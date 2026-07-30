# Ingest pipeline

The tracker, the endpoint, and the write path. This is the busiest code in the
application by a wide margin: it runs once per pageview on every measured site.

## The tracker

`lib/tracker/t.js`. Served unminified and unbundled, deliberately — a privacy tool
should be readable by the people it makes claims to. 7,649 bytes raw, 3,180
gzipped, 2,501 brotli.

```html
<script defer data-site="YOUR_SITE_KEY" src="https://your-tastatur/t.js"></script>
```

### What it transmits, completely

`payload()` is the only place data leaves the page:

| Field | Value |
|---|---|
| `s` | the public site token |
| `u` | current URL, **query string stripped except `utm_*`** |
| `n` | event name (`pageview`, or a custom name) |
| `r` | `document.referrer` |
| `w` | `window.innerWidth` |
| `p` | custom properties, when the caller supplies them |
| `v`, `c` | revenue amount and currency, when supplied |

Nothing else. No canvas, WebGL, font enumeration, audio context, plugin list,
battery, `hardwareConcurrency`, or timezone probing.

### Design points

**The endpoint is derived from the script's own URL**
(`script.src.replace(/\/[^/]+$/, '/api/event')`) rather than baked in. Proxying
the script through your own domain therefore proxies the events with it, with
nothing to reconfigure.

**Query strings are stripped in the browser**, before anything leaves the page.
Only `utm_*` survives. Query strings routinely carry password-reset tokens,
session ids and email addresses; the safest place to drop them is the earliest.

**`sendBeacon` first**, then `fetch(keepalive)`, then `XMLHttpRequest`. Only
`sendBeacon` reliably survives the page being closed or navigated away from,
which is exactly when the last pageview of a visit fires.

**`Content-Type: text/plain`** keeps the request a CORS *simple request*, so the
browser does not fire a preflight `OPTIONS` before every single pageview.

**SPA navigation** works by patching `history.pushState` and `replaceState` and
listening for `popstate`, with deduplication against the last URL sent. Without
the dedup, frameworks that call `replaceState` during hydration double-count the
initial pageview on every load. `pageshow` with `event.persisted` catches
back/forward cache restores, which do not re-run the script.

**Opt-out** honours Do Not Track and Global Privacy Control by default. Since we
store nothing on the device, a request header is the only durable objection signal
available to us — and a per-person opt-out flag would mean keeping a durable
identifier for precisely the people who asked us not to.

**Excluded by default:** `localhost`, `127.0.0.1`, `::1`, `*.local`, `192.168.*`,
`file:` and `about:`. Development traffic should not pollute real statistics.

### Additional surfaces

- **`GET /api/pixel`** returns a 1×1 GIF for `<noscript>`, inlined in the
  controller so the pixel path touches no filesystem.
- **`GET /api/event`** accepts the same payload as query parameters, for beacons
  that cannot POST.

## The endpoint

`Api::EventsController`, an `ActionController::API` subclass.

**Everything returns 202.** Accepted, bot-dropped, unknown token, malformed
payload, opted out, rate-limited: all 202 with no body. Two reasons. A
distinguishable response would let anyone enumerate valid site tokens. And an
error in a stranger's browser console on someone else's website is noise the site
owner cannot act on — a quietly dropped event is strictly better than a visible
error for a decision they cannot make from there.

This includes a query string the framework cannot parse. `?s=%` used to answer
400, with a full exception report per request, because
`ActionController::Instrumentation` parses the query string to build its log
payload before any controller-level rescue is in scope, and Rack::Attack touches
`params` earlier still. `Middleware::SanitizeIngestQuery` drops the unparseable
pairs before either of them looks, keeping the rest — so a POST whose body is
valid is still recorded even if something appended junk to the URL.

**The one exception is 413**, and it is deliberate. Puma refuses a request body
over 64 KB (`http_content_length_limit`) and Caddy refuses one at the edge for
these two paths. The largest body this endpoint can legitimately accept is about
17.4 KB, which is what the contract's own bounds allow, so no real tracker ever
approaches the limit. A 413 also leaks nothing: it depends only on the size of the
request and not on whether the token, hostname or payload was any good, so it
cannot be used to probe for valid tokens. Before the limit existed, a 5 MB beacon
was answered 202, with every byte read, parsed and held in memory by a thread that
could have been serving a real pageview.

**CORS allows any origin**, deliberately. The site token is public by
construction, so an origin allowlist protects nothing while breaking every setup
we cannot predict: staging domains, reverse proxies, AMP caches, embedded
iframes, a site served from both `example.com` and `www.example.com`. Origin here
is a hint, not a credential. The real protections are the token's unguessability
and the rate limits.

**Bot filtering** happens inline, before the write, using `device_detector`
(Matomo's list) plus explicit headless markers — `HeadlessChrome`, `PhantomJS`,
`Puppeteer`, `Playwright`, `Prerender`. Crawler traffic is the largest single
source of inflated numbers in self-hosted analytics, and once written it is
indistinguishable from a person's.

**Prefetch filtering** rejects `Sec-Purpose: prefetch` and `prerender`. Chrome and
Safari speculatively fetch links the user has not clicked; counting those inflates
everything.

**Rate limiting** (`config/initializers/rack_attack.rb`) uses **hashed** client
keys, not raw IPs. A stock Rack::Attack configuration writes every visitor's IP
into Redis for the length of the window, which is exactly what the rest of this
codebase goes to some trouble to avoid. A truncated HMAC is just as unique per
client. Limits: 600/min per client on ingest, 20,000/min per site as a circuit
breaker, 300/5min for everything else.

## Personal data in customer URLs

`Ingest::PathScrubber`. The most under-appreciated hole in a privacy-first
analytics tool, because stripping the query string is necessary but nowhere near
sufficient — real sites put personal data in the **path**:

```
/users/alice@example.com/settings        →  /users/:email/settings
/reset-password/eyJhbGciOiJIUzI1NiJ9...  →  /reset-password/:token
/invoice/7f3a91c2-4b8e-4c1a-9f2d-...     →  /invoice/:uuid
/orders/1048576                          →  /orders/:id
/f/9f86d081884c7d659a2feaa0c55ad015      →  /f/:hash
```

If those are persisted, "we store no personal data about your visitors" is false,
and it is our fault rather than the customer's. Segments are percent-decoded
before classification, so encoding cannot smuggle an email through.

The collapse is a reporting win as well: a million distinct invoice URLs are
useless as a top-pages table, and `/invoice/:uuid` is what the site owner wanted.

One deliberate exception: **four-digit numbers in 1900–2100 are kept as years.**
Date-organised URLs are extremely common (`/2026/07/roundup`, `/blog/2025/hello`)
and collapsing the year would destroy the top-pages report for every publication
that uses them. This was caught by a spec, not by inspection.

Query parameters have an allowlist (`utm_*`, `ref`) *and* a deny-list that wins
over it (`token`, `code`, `key`, `secret`, `password`, `email`, `phone`,
`access_token`, `session`, `auth`, `signature`, `state`, `otp`, …), so a future
widening of the allowlist cannot accidentally start capturing credentials. A
`utm_source` that looks like a token or contains an `@` is also dropped.

## The write path

`Ingest::WriteBuffer`.

**Why not a direct INSERT.** The endpoint runs during the customer's page load
and must answer in single-digit milliseconds. A per-event round trip to
PostgreSQL puts a transaction, a WAL flush and an fsync on that path. Batching a
few hundred events into one multi-row INSERT turns hundreds of transactions into
one.

**The mechanism.** The request `RPUSH`es one JSON payload onto a Redis list and
returns. A flush drains up to 250 at a time with `LPOP key count` and issues a
single multi-row INSERT. Flushes trigger on **size** (buffer ≥ 250, enqueues
`FlushEventBufferJob`) or **age** (a one-minute cron backstop, for the quiet site
whose buffer would otherwise sit unflushed between visits). `LPOP` is atomic, so
concurrent flushes are safe and no event is popped twice — hence no lock.

**The trade, stated explicitly.** Events live in Redis for up to the flush
interval before they are durable. If the process dies in that window, those
events are lost. For analytics that is the right trade: a handful of missing
pageviews is invisible in aggregate, while making every pageview
durable-on-arrival would cost an order of magnitude in throughput. It is written
down because it is a real trade and not an oversight — **anything that must not
be lost does not belong in this table.** On a failed INSERT the batch is pushed
back before the error is re-raised, so a transient database problem does not eat
events.

**Binary columns travel as hex** through Redis so the payload stays valid JSON,
and are converted back to `bytea` on the way into PostgreSQL.

## Enrichment cost

| Step | Cost |
|---|---|
| Site lookup | `Rails.cache`, 60 s TTL. A miss is one indexed query; the short window means deleting a site stops collection promptly |
| User-agent parsing | `device_detector`, in-process |
| Geolocation | `MaxMind::DB` in `MODE_MEMORY`, mmapped once per process, thread-safe for reads. No allocation and no I/O syscall in the steady state. Absent database → `nil` country, and the app still works |
| Identity | two Redis round trips (salt read, session `GETEX`) |
| Write | one Redis `RPUSH` |

Measured warm latency: **~8 ms** per request in development mode with full
logging, on a laptop. Production should be materially faster; the first
bottleneck at scale is the Redis round trips, which is why they are two and not
five.

## Throughput notes

Puma's thread count bounds concurrent ingest. Because each request does no
synchronous database write, threads are held only for Redis round trips, so a
small pool goes a long way. When ingest volume becomes the constraint, the levers
in order are: raise `INGEST_FLUSH_SIZE`, scale the `worker` process serving the
`within_30_seconds` queue, then move ingest to its own Puma process so a slow
dashboard query cannot starve it.

Raising `SIDEKIQ_CONCURRENCY` is not on that list, and measurement is why: 150,000
buffered events took 6.85 s to flush at concurrency 5 and **8.39 s** at
concurrency 15. The multi-row INSERT is the bottleneck, so more threads only add
contention. Sidekiq also sizes its own Redis pool from that setting and leaves the
ActiveRecord pool alone, so raising it far enough eventually exhausts database
connections instead.

The flush job sits in `within_30_seconds` rather than the top tier deliberately.
Queues are drained in strict priority order, so putting frequent bulk writes above
transactional mail would let a busy site's flushes queue in front of somebody's
confirmation email.
