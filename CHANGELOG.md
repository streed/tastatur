# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Two rules specific to this project:

- **Anything that changes what data is stored, derived, or retained gets an entry**,
  under a `Privacy` heading, whether or not it is user-visible. A self-hoster
  deciding whether to take an upgrade needs to know that before they read the diff.
- **Anything that changes a claim on the `/privacy` page gets an entry**, including
  a correction to a claim that was too strong. Those are the entries most worth
  writing down, and the easiest to quietly skip.

## [Unreleased]

### Added

- Core dashboard: visitors, pageviews, sessions, bounce rate and average duration,
  with server-rendered SVG charts and no client-side charting library.
- Breakdowns for pages, entry pages, referrer sources, countries, browsers, devices
  and UTM campaigns, each with k-anonymity suppression applied.
- Funnels with per-step conversion and drop-off, steps addable and removable in the
  form rather than a fixed number of rows.
- Goals and conversion tracking, for both pageview paths and custom events.
- Custom event properties are now readable. `tastatur('event', 'Signup', { props:
  { plan: 'pro' } })` has been accepted, validated and stored since the beginning
  and displayed by nothing, so following the documented call produced data no
  screen could show. Scoping the dashboard to a custom event now renders a card
  per property key with its top values, and a value can be filtered on
  (`?props[plan]=pro`). Shown only against a chosen event, because the same
  property on two different events is not one fact.
- Public shareable dashboards, with an optional password and an expiry.
- Team accounts with invitations and roles, enforced through Pundit policies.
- Self-hosting mode: billing and plan limits switched off, a first-run setup wizard,
  and a one-command `docker compose` deployment.
- A subject-access page that derives the caller's own identifier from their live
  connection, so someone can see their own rows without proving an identity the
  system deliberately cannot check.
- An email on the first event a site receives, since the gap between installing the
  snippet and seeing anything is the point where people give up.
- Two plans on the hosted service: Free (100,000 events a month, one site) and Pro
  ($40 a month, 10,000,000 events, twenty sites). Teammates are unlimited on both —
  per-seat pricing on an analytics tool means the person who most needs the numbers
  is the person nobody wants to pay for. A self-hosted install has neither plans nor
  limits and never touches Stripe.
- Stripe hosted Checkout and the Stripe billing portal, so no card number reaches
  this application and cancellation, invoices and VAT details are handled where they
  are already handled properly. Webhooks are idempotent through a
  `processed_webhook_events` receipt, and a nightly reconciliation re-reads every
  subscription from Stripe so a webhook Stripe gave up delivering cannot leave an
  account on the wrong plan.
- Monthly event allowances, metered on the ingest path and reconciled hourly against
  the `events_by_hour` aggregate. Events past the allowance are not recorded and
  there is no overage charge; owners are emailed at 80% and again if the
  allowance runs out, and refused events are shown on the site's settings screen
  rather than disappearing. Bot traffic and events claiming a hostname that is not
  the customer's are dropped before metering, so no allowance is spent on
  measurement nobody can read. See `docs/architecture/billing.md`.
- Downgrading never deletes anything and never cuts the month short: an account that
  cancels Pro keeps all twenty sites collecting, is simply unable to add a
  twenty-first, and keeps the smaller plan's full event allowance for the remainder of
  the month it downgraded in rather than finding the month already spent.
- Only owners see or are emailed anything about billing, matching the policy that
  guards the recurring charge. Every link in the interface that needs a permission is
  now shown only to somebody who has it.
- Billing stays switched off until Stripe is actually configured, not just until
  `SELF_HOSTED` says so. A deployment with no Stripe keys previously enforced plan
  limits — one site, 100,000 events — behind an upgrade button whose only possible
  answer was "payments are not configured on this instance". Now there are no limits,
  no upgrade interface, no pricing page and no webhook endpoint until the keys are
  present, at which point it switches itself on. The boot log says
  `BILLING IS DISABLED` and names what is missing, because the safe state is not
  necessarily the intended one. Selling and managing are separate: an instance that
  can no longer sell still lets anyone who already subscribed cancel, change their
  card or read their invoices, because Stripe keeps charging them either way and
  taking the money while removing the cancel button is not a state to reach by
  misconfiguration.

- Optional two-factor authentication on sign-in, by emailed six-digit code. Off by
  default and switched on per person from the account page, because it protects a
  login rather than an account — the same switch covers every account that person
  belongs to, and an account owner cannot set it for their teammates. A browser can
  be trusted for thirty days so a daily user is not challenged every morning, and
  those devices are listed and revocable individually or all at once. Email is a
  weaker second factor than an authenticator app and the settings screen says so
  rather than implying otherwise.
- An instance administrator can turn somebody's two-factor authentication off, and
  cannot turn it on. That asymmetry is the point: the off switch is the remedy for a
  person locked out because the mailbox their codes go to stopped working, and an on
  switch would let an operator aim a customer's codes at an address they control.
- The marketing page and the docs answer `Accept: text/markdown` with a markdown
  rendering of the same content (also fetchable directly as `/index.md` and
  `/docs.md`), for LLM agents and AI crawlers that read pages as text. Browsers
  are unaffected — a request that prefers HTML still gets HTML. An `/llms.txt`
  index (llmstxt.org) points agents at the markdown pages and the policy
  documents, listing pricing only where billing is actually enabled.

### Privacy

- Custom event property values are now displayed, and are subject to the same
  k-anonymity threshold and complementary suppression as every other breakdown row.
  This is the first breakdown in the application whose row values are chosen entirely
  by the customer rather than derived from a request, so a single row can be a single
  person by construction rather than by coincidence — which is why the suppression was
  moved into `Analytics::Suppression` and shared, instead of reimplemented alongside
  the new query. Property panels are not rendered on public shared dashboards, which
  are deliberately unfiltered.
- Tastatur's own self-measurement records that somebody filtered by a property, never
  which property. A property key is the customer's own schema — `plan`, but equally
  `user_id` or `email_domain` — and putting it in our analytics database is the thing
  the rest of this list exists to prevent. Same rule that already keeps breakdown row
  values out of those events; `spec/requests/event_properties_spec.rb` pins it.
- The dashboard sets a third first-party cookie when somebody uses two-factor
  authentication and asks not to be challenged on a particular browser: a random
  value, valid for thirty days, matching a row they can delete at any time. Like the
  other two it is strictly necessary for a login and is disclosed on `/privacy`, in
  the privacy policy and in the cookie notice, all of which previously said "one, and
  a second if you ask to be remembered".
- The trusted-device list deliberately records no browser name, operating system or
  location. Every comparable product puts them on that screen and they would genuinely
  help somebody recognise a device — but they are derived from a user-agent and an IP
  address, which this project says it keeps for neither visitors nor, in that form,
  account holders. A device is identified to its owner by when it was trusted and when
  it was last used. `spec/privacy_invariants_spec.rb` fails a migration that adds such
  a column.
- Sign-in codes are stored as bcrypt digests, never in the clear, and are destroyed
  on use, on expiry, and after five wrong guesses.
- Visitor identity is an HMAC-SHA-256 digest of a daily-rotating random salt, the
  site id, the IP address and the user-agent, truncated to 128 bits. The IP and
  user-agent exist as local variables and are never written to the database, a log,
  or disk. IPv6 addresses are normalised to a /64 first.
- The rotating salt lives only in a separate, non-persistent Redis, with RDB
  snapshots and the AOF both disabled. Once a salt is destroyed the data derived
  from it is unlinkable rather than merely pseudonymous.
- Salts are random and never derived from a long-lived key, so historical salts
  cannot be regenerated.
- Geolocation resolves to a two-letter country code only. No region, city,
  coordinates, or network operator.
- Personal data is stripped from path segments as well as query strings.
- k-anonymity thresholds on every breakdown, with complementary suppression: when
  exactly one row falls below the threshold, a second is also withheld, because
  otherwise the hidden value is the reported total minus the visible rows.
- Retention defaults to 12 months, following the research on how far back small
  sites actually look, with a global backstop above the highest configurable value
  rather than below it.
- Corrected two overstated claims. The `/privacy` page said `Ingest::Identifier` was
  the only code in the repository that touches an IP address, which was not true:
  two controllers read it from the request to pass it on, and Devise records an
  account holder's sign-in IP. The privacy policy enumerated sign-in metadata as
  "counts and timestamps" under the words "that is the complete list" while omitting
  the IP columns beside them. Both now state the account-holder exception plainly.
  See [docs/privacy/claims.md](docs/privacy/claims.md).

### Security

- Devise `paranoid` mode is on, so password reset and confirmation resend no longer
  disclose whether an address has an account here. On a single-company instance that
  answer discloses who works there.
- Confirmation tokens expire after three days. The default is never, which leaves a
  working credential sitting in an inbox indefinitely.
- Minimum password length raised from six to eight, per NIST SP 800-63B. The maximum
  stays high: bcrypt truncates at 72 bytes anyway, and rejecting a long passphrase
  teaches the wrong lesson.
- Rate limits added to the confirmation and unlock endpoints, which both send mail
  to a caller-supplied address and were the two such flows left unthrottled.
- `--color-muted` darkened to meet WCAG AA. It measured 3.37:1 against the card
  surface, under the 4.5:1 needed for normal text, and it carries the 10px labels
  and chart axis text — the smallest type in the application. Now 5.20:1.
- Ingest is checked against a site's configured hostnames, so copying someone's
  snippet onto another domain does not let you write events into their site.
  Rejections are counted per site, reason and hour, with no visitor identifier and
  no IP.
- Rate limiting via Rack::Attack, with counters in Redis rather than a per-container
  file store, where every limit would otherwise be silently multiplied by the number
  of replicas. The ingest path answers 202 when throttled so a measured site never
  sees an error from us.
- Session cookies are marked secure in production, and HSTS is set.
- A correct password no longer produces a session of any kind when a second factor
  is outstanding. The obvious implementation — sign in, then block every request with
  a `before_action` until the code is entered — was rejected because `/sidekiq` is
  mounted behind a Warden check inside `config/routes.rb`, where no controller
  callback runs; a "signed in but gated" session would have walked a stolen admin
  password straight into the job console. The Warden session is torn down and all
  that remains is a ten-minute marker carrying the user id, a remember-me preference
  and the authenticatable salt, so a password changed in between invalidates it.
- Adding a site now requires a confirmed email address, in `SitePolicy#create?`
  rather than only in Devise's configuration. Unconfirmed users cannot hold a session
  today, so this is belt and braces — which is exactly why it is written down: the
  guarantee otherwise rests on `allow_unconfirmed_access_for` being `0.days`, and
  relaxing that to let new users look around before confirming would silently hand
  site creation to anyone who can type an address they do not own. Reading and
  deleting are deliberately not gated.
- Fixed a redirect loop reachable by two ordinary people. The site list redirected an
  empty account to the "add a site" form, the form refused anyone without permission,
  and `deny_access` redirected back to the list using the referer — round and round.
  A viewer in an account whose sites had all been deleted could reach it, and the
  confirmation rule above would have made it reachable for unconfirmed users too. The
  list now only redirects somebody who could actually create a site.

### Changed

- The dashboard's eight breakdown panels now come from a single scan instead of
  eight. They ran the same query with the same conditions once per panel, which was
  effectively the entire cost of the page: measured on 600,000 events over 90 days,
  1,233 ms for the panels against 2–12 ms for everything else, since the summary and
  timeseries read the continuous aggregates. One `GROUPING SETS` pass brings it to
  836 ms. The suppression code is untouched and shared by both paths, and a spec
  asserts the batch output is identical row for row, including suppression counts.
  See [docs/architecture/performance.md](docs/architecture/performance.md), which
  also records two optimisations that measured *worse* and were rejected.
- Sidekiq queues are named for the latency they promise rather than for the work
  they carry: `within_5_seconds`, `within_30_seconds`, `within_5_minutes`,
  `within_1_hour`, served in that order. A queue name now answers "what breaks if
  this backs up", monitoring is one rule instead of one per queue, and a new job
  has an obvious home. `config/sidekiq.yml` is the list of served queues, and
  `spec/jobs/queue_names_spec.rb` fails if a job, a cron entry, or a framework
  default points anywhere else.

### Fixed

- **Filtering the dashboard by a custom event reported "0 pageviews" above panels
  full of the visitors who fired it.** The filter pins `event_name` in the WHERE
  clause and "pageviews" counts events named `pageview` — two conditions that can
  never both hold, so the tile, the chart's volume line and the goal panel were all
  structurally zero the moment the one panel built to surface custom events was
  clicked. The volume metric now switches to the matching events themselves,
  labelled "Events" wherever it is named; visits, bounce rate and duration were
  already session-scoped and are unchanged. Goals the filtered event cannot satisfy
  are dropped from the goal panel rather than shown as "0.0%", which read as "this
  goal stopped converting" while measuring a contradiction.
- **The chart clipped the visitors line whenever a bucket had more visitors than
  pageviews.** The y-axis was scaled to the pageviews series alone, so the taller
  visitors line was drawn above the plot area and the viewBox cut it off — on an
  event-filtered dashboard that was every bucket, and the whole chart rendered
  empty. Both series now bound the scale.
- **Entry pages went degenerate under any filter.** The filter was ANDed onto
  `is_entry`, so filtering by the page everyone visited emptied the panel of
  everything except (at most) that page itself, and filtering by a custom event
  emptied it entirely. Entry pages are session-grain: the filter now selects
  sessions — the same rule bounce rate and duration already follow — and the panel
  shows where those sessions began.
- **Breakdown percentages divided by the wrong total.** The denominator was the sum
  of per-row visitor counts, which counts a visitor once for every value they
  appear under — a visitor who read three pages inflated the pages denominator
  threefold. Percentages were computed and never rendered, so nothing visible was
  wrong yet; the denominator is now the distinct-visitor count for the scope, so
  the first consumer inherits a number that means "share of the audience".
- **An existing user added to an account was told nothing at all.** Their site list
  quietly grew and they were left to notice. A brand-new invitee fared only slightly
  better: they got Devise's bare password-reset email, which out of context reads as
  "somebody tried to reset my password" and never says who invited them or to what.
  `MemberInvitationMailer` now carries the same token with the context attached, and
  covers both cases. It also says what to do if the invitation was unexpected, since
  that is precisely the shape of a phishing message.
- The four static error pages were the framework defaults. They now match the rest
  of the product, are entirely self-contained (they are served when the application
  cannot be, so they can use neither the asset pipeline nor the webfont), and follow
  the reader's dark-mode preference.
- **Revenue from different currencies was added together.** `SUM(revenue_cents)`
  ignored the currency column, so a site taking euros and dollars saw them summed
  into one figure with no unit: 4900 EUR + 2500 EUR + 9900 USD + 5000 JPY came out
  as "22300". The tracking API takes a currency on every revenue event and the
  documented example uses EUR, so mixed currencies are the expected case. Revenue is
  now reported per currency, and rendered — it was previously computed and never
  shown at all. No exchange-rate conversion, because that would mean picking a rate
  and a date and presenting the result as though it were measured.
- **Both legal documents claimed to have been revised today, every day.** They
  rendered `Date.current`, so a reader checking whether the terms had changed since
  they agreed to them was told "today" no matter what. Now driven by
  `LEGAL_UPDATED_ON`, which shows nothing when unset and is parsed strictly —
  `Date.parse` reads "last tuesday" as a real date, which would put a confident
  wrong date on a legal page.
- **The DPA had no "not configured" banner**, unlike the policy and terms, so an
  unconfigured instance published a processing agreement naming nobody.
- **The docs and the privacy page both said screen width is bucketed into "six"
  sizes.** There are five.
- **`destroy_all!` left the session map behind.** It deleted the two salt keys and
  logged "ALL visitor salts destroyed", while every
  `tastatur:session:<site>:<visitor_hash>` entry survived — keys that contain a
  visitor hash by construction and map it to a live session, which is exactly the
  linkable state an operator running the purge wants gone.
- **The chart had no usable text alternative.** `role="img"` with a summary label
  told a screen reader "peaking at 1,240 visitors" and stopped, which is a caption
  rather than the data. Every plotted point is now also a visually-hidden table.
- **No statement timeout.** One expensive dashboard query could hold a connection
  indefinitely, and with a small pool a handful of those is the whole pool. Capped
  at 15s for web, explicitly disabled for the worker, whose aggregate refreshes and
  retention deletes legitimately run for minutes.
- Duration was rendered as "61m 40s" past an hour, and as "45.30000000000001s" from
  a float average.
- The goals table overflowed a 375px viewport by 89px, which was the actual cause
  of the dashboard's sideways scroll rather than the header.
- Creating a site 500'd for a signed-in user whose only account had been deleted.
- **The 12-month chart drew a flat line at zero.** The bucket series is generated
  in Ruby and matched against `time_bucket`'s output by equality, but it started at
  the report's own start date while `time_bucket` aligns weeks to Monday and months
  to the 1st. Every bucket existed in Ruby and nowhere in the result set, so every
  lookup missed. Measured: 0 pageviews charted against 17,286 real ones. The day and
  hour presets were unaffected, because midnight is already aligned, which is why
  the two views people check most looked fine while the annual one was empty.
- **Bounce rate and duration were wrong whenever a filter was applied.** The filter
  was applied before the session rollup, so each session was measured over only its
  matching events: a visit that saw `/pricing` and five other pages counted as a
  one-page bounce lasting no time. Measured on two sessions: 100% bounce rate and 0s
  average against a true 50% and 150s. The error always ran the same way, so a
  filtered page looked worse than it was in a plausible, alarming manner.
- **Nobody could create an account on an instance with no mail provider.** With
  `RESEND_API_KEY` unset, delivery raised — but the account had already been
  committed, because Devise confirms from an `after_commit` hook. The result was a
  500, an unconfirmed account that could not sign in, and an email address
  permanently taken. Mail now degrades to the log so the operator can retrieve the
  confirmation link, with a boot warning that says links are being written in clear.
- **A subject-access request missed half its window.** The lookup searches 48 hours,
  which spans two salt generations, but only ever computed the current salt's
  digest, so everything written before the last rotation was unreachable. Someone
  asking an hour after rotation was told we held nothing about them.
- **Opt-outs were counted for almost nobody.** The counter read the site token from
  `params[:s]`, and the tracker posts `Content-Type: text/plain` to stay a CORS
  simple request, which Rails does not parse into `params`. Only the noscript pixel
  was ever counted, so the dashboard's "some visitors send Do Not Track" figure
  understated the gap it exists to explain.
- **`verify_policy_scoped` never ran.** It required `action_name == "index" && !pundit_exempt?`
  while `pundit_exempt?` returned true *for* index, so the condition was
  unsatisfiable. Tenant isolation on index pages was resting on a callback that
  could not fire. Every index action does scope correctly; what was missing was the
  thing that notices when a new one does not.
- **Every fresh production deployment created a publicly known administrator.**
  `db/seeds.rb` created `admin@example.com` / `password` with `admin = true`
  unconditionally, `db:prepare` seeds a database it has just created, and
  `bin/docker-entrypoint` runs `db:prepare` on boot. This is a public repository,
  so those credentials are published, and that account can reach `/sidekiq`.
  Confirmed by seeding an empty database with `RAILS_ENV=production`: both users
  appeared, with no warning anywhere. Guarded twice now, by an environment check in
  the seed file and by `seeds: false` on the production database; a fresh
  production database comes up with zero users. A self-hosted instance gets its
  first administrator from the first-run wizard, where the operator picks the
  password.
- **An account could be left with no owner.** The last-owner check only ran
  `on: :update`, so demoting the last owner was refused while deleting them was
  allowed, through `DELETE /account/members/:id`. Owner is the role that manages
  members, so the account became permanently unadministrable with nobody able to
  appoint a replacement. Deleting the account itself still works, which is the case
  a naive guard breaks.
- **The opt-out counter let anyone write unbounded keys into Redis.** It
  interpolated an unauthenticated site token straight into a key with a 45-day TTL,
  checking only that it was not blank, so a request with `DNT: 1` and a fresh random
  token created a new key every time. The token's shape and existence are now both
  checked first.
- **No event ever reached PostgreSQL on a clean deployment.**
  `FlushEventBufferJob` declared `queue_as :ingest`, no `config/sidekiq.yml`
  existed, and a bare `bundle exec sidekiq` serves only `default`. So the job that
  moves buffered events out of Redis was enqueued by cron every minute and executed
  never: Redis grew without bound, dashboards silently stopped advancing, ingest
  kept answering 202, and nothing raised. It was invisible in development because a
  worker had been started by hand with `-q ingest`, and invisible in the suite
  because the test adapter runs jobs inline and never consults a queue name.
- **One request could stop ingest for every site on the instance.** A NUL byte in
  an event name, or a revenue value above the `revenue_cents` int4 ceiling, was
  accepted with a 202 and buffered, then failed on INSERT. A failed batch was
  returned to the shared buffer and re-raised, so the flush job retried it forever
  and no site's events were written again. The int4 case needed no hostility at
  all: a purchase in a minor-unit currency such as IDR or VND can exceed it. The
  contract now rejects both at the boundary, `WriteBuffer` scrubs text on the way
  in, and a row the database structurally refuses is isolated by bisecting the
  batch and set aside in a capped quarantine so everything else still lands.
- **The ingest endpoint answered 400 for a query string Rails could not parse**,
  such as `?s=%`, and logged a full exception report for each one. That broke the
  documented promise that this endpoint is indistinguishable whatever it is sent.
  It could not be fixed in the controller: `ActionController::Instrumentation`
  parses the query string to build its log payload before any `rescue_from` is in
  scope, and Rack::Attack touches `params` earlier still, so
  `Middleware::SanitizeIngestQuery` now drops the unparseable pairs before
  anything reads them. A valid body alongside a junk query string is still
  recorded, and other paths still return 400, where that is the useful answer.
- **A Redis outage made ingest answer 500**, which would print an error in the
  browser console of every page of every measured site, about a problem the site
  owner cannot act on. Storage failures now yield a quiet 202 and are reported to
  Sentry explicitly rather than swallowed.
- Caddy emitted **two conflicting `Cache-Control` headers** on the tracker script,
  one hour and one year. A plain `header` directive is applied before the proxy
  runs and `reverse_proxy` then adds the upstream's own value rather than
  replacing it, and RFC 9111 does not say which wins, so the effective policy
  varied by client. `/t.js` is not digest-stamped, so the short window is the only
  invalidation lever there is.
- Mail had the same defect waiting. `deliver_later_queue_name` was unset, which
  under Rails 8 defaults routes mail to `default` — also unserved. Transactional
  mail now goes to `within_5_seconds`, and `default_queue_name` is a served queue
  so a job that forgets `queue_as` runs late instead of disappearing.
- Deleting a site left visitor hashes in the continuous aggregates. The refresh
  policies only look back a few days, so an older invalidation was never processed
  and erased data kept appearing in reports. Bulk deletion now reconciles the
  affected window.

[Unreleased]: https://github.com/streed/tastatur/commits/main
