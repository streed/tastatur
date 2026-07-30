# Geolocation

Tastatur resolves an IP address to a **two-letter country code** and stops. No
region, no city, no coordinates, no network operator.

That is a product limit, not a gap. City-level location combined with a device
profile and a visit time is identifying for a person in a small town, which is
precisely the inference this product exists to avoid. A country code shared with
millions of people is not.

## Enabling it

The database is not bundled. Fetch it:

```bash
docker compose exec web bin/rails tastatur:geoip:download
bin/rails tastatur:geoip:status      # verify
```

Until you do, country breakdowns are empty and everything else works normally.
Geolocation is an optional enrichment, so a fresh install is usable immediately.

## If every country says "Unknown" — check the proxy chain first

A working database with the wrong IP address looks exactly like a missing
database. Before re-downloading anything:

```bash
bin/rails tastatur:geoip:status        # is the database there?
bin/rails tastatur:cloudflare:status   # is the right address reaching it?
```

The second one works a realistic chain end to end and tells you whether the
address it resolves is the visitor's or a proxy's.

**Why this happens.** Rails trusts loopback and the RFC 1918 private ranges, and
takes the right-most address in `X-Forwarded-For` that is not one of them. With a
public edge in front, that address is the edge:

```
client → Cloudflare → platform → app
X-Forwarded-For: 24.48.0.1, 172.71.150.22
                 ^ the visitor  ^ Cloudflare, a public address
```

Depending on the last hop this reports either a wrong country for everybody (the
edge's) or none at all (a carrier-grade NAT or IPv6 unique-local address, which
no database has an entry for).

**This costs far more than a country column.** `Ingest::Identifier` mixes the
address into the visitor HMAC, so if every request resolves to the same proxy,
every visitor behind it becomes *the same visitor*. Unique visitors and visits
are both undercounted, and the breakdown that made the problem visible was the
least of it.

**The fix.** Tell the application what sits in front of it:

| Variable | Set it to |
|---|---|
| `TRUST_CLOUDFLARE` | `true` if your site is proxied through Cloudflare |
| `TRUSTED_PROXY_RANGES` | comma-separated CIDRs for any other edge — another CDN, a load balancer, a bastion |

Carrier-grade NAT (`100.64.0.0/10`) and IPv6 unique-local (`fd00::/8`) are always
trusted and need no configuration: neither is routable, so neither can ever be a
visitor. They are absent from Rails' list only because they postdate it.

`TRUST_CLOUDFLARE` uses Cloudflare's published ranges from
`config/cloudflare_ips.yml` rather than believing the `CF-Connecting-IP` header.
Most guides suggest the header; it is the wrong advice whenever your origin stays
reachable directly, because a header you trust unconditionally is a header
anyone can set — and forging it picks your country, your visitor identity and
your rate-limit bucket. Trusting the *range* leaves a forged `X-Forwarded-For`
entry sitting to the left of the real client, which is exactly where the
right-most rule ignores it.

It is off by default because Cloudflare's ranges are also the exit addresses of
Cloudflare WARP. On an install that is *not* behind Cloudflare, trusting them
would throw away the real address of every WARP user.

Refresh the range list when Cloudflare publishes changes — rarely — with
`bin/rails tastatur:cloudflare:refresh`. A stale list fails visibly rather than
silently: an unknown range is treated as the client, so countries go wrong again
instead of quietly going right.

## Which database, and why

**DB-IP IP-to-Country Lite**, under CC BY 4.0.

| | DB-IP Lite | MaxMind GeoLite2 |
|---|---|---|
| Account required | no | **yes**, since Dec 2019 |
| Licence key per download | no | **yes** |
| EULA acceptance | no | **yes** |
| Redistribution | permitted with attribution | **paid licence** |
| Auto-update mandated | no | yes, with no way to pin |

GeoLite2 is the better-known dataset, but every row in that right-hand column
breaks either "set up in minutes" or self-hostability. It remains usable if you
have your own key: point `GEOIP_DB_PATH` at your own `.mmdb` and Tastatur will
read it, since both are MaxMind-format files.

IP2Location LITE was also considered and rejected: CC BY-SA 4.0's share-alike
provision raises live questions for derived datasets.

## Attribution is required

CC BY 4.0 obliges you to credit DB-IP wherever this data is surfaced. Tastatur
already does so at the bottom of `/privacy`:

> IP Geolocation by DB-IP

If you remove or rewrite that page, put the credit somewhere else. This is a
licence condition, not a courtesy.

## Keeping it current

DB-IP republishes monthly and removes older files. The download task tries the
current month and falls back one month. Refresh it periodically:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails tastatur:geoip:download
```

A stale database misattributes a small and slowly growing share of addresses. It
is worth a monthly cron but not worth losing sleep over.

## How it is read

`MaxMind::DB` in `MODE_MEMORY`, mmapped once per process and thread-safe for
reads, so a lookup costs no allocation and no I/O syscall in the steady state.
A missing file is memoized as `nil`, so an install without the database does not
re-check the filesystem on every request.

## Accuracy

Country-level IP geolocation is roughly 95–99% accurate for consumer
connections, and worse for:

- corporate VPNs, which resolve to wherever the exit node is
- mobile carriers routing through a national gateway
- cloud and datacentre ranges, which are registered rather than located
- privacy VPNs and Tor, which are the point

`1.1.1.1` resolves to `AU` because Cloudflare's resolver is registered in
Australia, which illustrates the difference between "registered" and "located".
Treat country breakdowns as a good estimate of your audience's distribution, not
as a census.
