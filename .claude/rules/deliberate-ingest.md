---
paths:
  - "app/lib/ingest/**/*.rb"
  - "app/services/ingest/**/*.rb"
  - "lib/middleware/**/*.rb"
  - "config/initializers/rack_attack.rb"
  - "config/initializers/cors.rb"
  - "spec/lib/ingest/**/*.rb"
  - "spec/services/ingest/**/*.rb"
  - "app/controllers/api/**/*.rb"
  - "docs/architecture/ingest.md"
---

### 12. Things that look like bugs but are deliberate (ingest)

Before "fixing" any of these, read the linked document.

- **The ingest endpoint always returns 202**, even for an unknown site token or a
  malformed payload. A distinguishable response lets anyone enumerate valid
  tokens, and an error in a stranger's console on a customer's site is noise they
  cannot act on. `docs/architecture/ingest.md`
- **CORS allows any origin** on ingest. The site token is public by construction,
  so an allowlist protects nothing and breaks staging domains, proxies and
  iframes.
- **Rate-limit keys are hashed, not raw IPs.** A stock Rack::Attack config writes
  every visitor's IP into Redis, which is the thing this codebase avoids
  everywhere else.

- **`Ingest::PathScrubber` collapses every numeric path segment to `:id`** —
  regardless of digit count, because `/player/51` names an individual just as
  `/orders/1048576` does — with one date-shaped exception: a four-digit year
  (1900–2100) is kept, as is the month and day that immediately follow it
  (`/2026/07/15`). Date-organised URLs are common and collapsing the year
  destroys the top-pages report; a bare short number outside that date run is a
  record id and must not survive. The scrub is position-aware for this reason.
- **A site's declared route patterns are the exact path scrubber, and the shape
  heuristics are the fallback.** By shape alone a short or word-shaped id
  (`/player/51`, a 16-char `Site#public_token` at `/sites/:token`) cannot be told
  from a page name, so a site lists its route templates and
  `Ingest::PathPatternMatcher` compiles them into a segment trie; `PathScrubber`
  walks the trie first and hands the undeclared tail to the heuristics. Matching
  is greedy (literal beats param, no backtracking), consumes only the declared
  prefix, and an empty pattern list is a pure-heuristic scrub. Patterns are
  per-site (`sites.path_patterns`, edited as a newline textarea like
  `extra_hostnames`) and validated on the model. The heuristic fallback also
  collapses a 16+ char alphanumeric run that mixes letters and digits, so an
  undeclared site still loses its tokens; it stays digit-gated so a camelCase page
  is left alone. `spec/lib/ingest/path_pattern_matcher_spec.rb`.

- **The write buffer builds its INSERT by hand.** It is the ingest hot path;
  `insert_all` per event costs an order of magnitude. Values are all passed
  through `connection.quote` and the column list is a frozen constant. The
  Brakeman warning is a reviewed false positive recorded in
  `config/brakeman.ignore`.
