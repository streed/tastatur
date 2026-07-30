# Claims

What this project will and will not say about itself, and why. This is a
practical document: the phrases below are the ones that get privacy-first
analytics tools into trouble, and every one of them is easy to write by accident.

If you are adding marketing copy, a feature description, or a README line, check
it against this.

## Never say these

### "No cookie banner needed"

Unqualified, this is false. It depends on three things we do not control:

- **Jurisdiction.** Germany's TDDDG §25 has only two exceptions — transmission,
  and strictly necessary for an expressly requested service — and **no
  audience-measurement carve-out**. The DSK's guidance treats analytics as
  consent-requiring. Our honest German position is "we store nothing on the
  device, so §25 is arguably not engaged at all", never "no banner needed in
  Germany".
- **Configuration.** Regulators that do offer an audience-measurement exemption
  attach conditions. CNIL's July 2025 self-evaluation tool explicitly requires
  non-audience-measurement purposes to be **disabled by default**, naming
  campaign-performance and conversion-channel measurement — which is precisely
  our goals, funnels, revenue and UTM features.
- **Everything else on the customer's site.** If any other script needs consent,
  they need a banner regardless of us.

**Say instead:** "Tastatur sets no cookies and stores nothing on your visitors'
devices. In many EU and UK configurations Tastatur alone does not require a
consent banner. You still need one if any of your other tools do, and the answer
depends on your jurisdiction — take your own advice."

### "100% GDPR compliant" / "GDPR compliant"

Compliance is a property of a controller's entire processing operation, not of a
product. No tool can confer it. **Say instead:** describe the specific
properties — no cookies, no device storage, no cross-site identifier, retention
you configure, a DPA we will sign.

### "We collect no personal data"

False. We receive an IP address on every request, which is personal data under
GDPR (*Breyer*, C-582/14) and expressly listed as personal information under the
CCPA. **Say instead:** "Your visitors' IP addresses reach our server, as they do
with every HTTP request. They are used in memory to derive a rotating digest and
a country code, and are never written to the database, a log, or disk."

Being straightforward about this is more persuasive than the false version,
because anyone technical knows the false version cannot be true.

### "We never store IP addresses" / "the only place that touches an IP"

Two different statements hide here, and only one of them is true.

**True, and worth saying:** no *visitor's* IP address is ever persisted. It exists
as a local variable while a request is served and is used for exactly two things,
a digest and a country lookup.

**False:** that no IP is stored anywhere, or that `Ingest::Identifier` is the only
code that touches one. Devise's trackable module records
`current_sign_in_ip` and `last_sign_in_ip` for **account holders**, so that a
customer can notice a sign-in that was not theirs. Two controllers also read
`request.remote_ip` in order to pass it along: the ingest endpoint, and the
subject-access page, which derives the caller's own identifier from their live
connection so it can show them their rows.

The privacy page said the sweeping version for a while, next to an enumeration in
the policy that listed "sign-in counts and timestamps" under the heading "that is
the complete list" while omitting the IP column sitting beside them in the same
table. Both are fixed. The lesson generalises: an incomplete enumeration is worse
than a vague sentence, because a specific list invites the reader to conclude that
anything absent from it does not exist.

**Say instead:** name the subject. "No visitor's IP is stored" is a strong claim
and it survives inspection. Pair it with the exception, in the open — the
account-holder sign-in IP is a security feature for the customer's benefit and
reads as one when it is disclosed, and as a caught lie when it is not.

### "Fully anonymous" / "Anonymous by design"

While a salt is live, data derived from it is **pseudonymous**. The mapping is
computable by whoever holds the salt. **Say instead:** "pseudonymous while the
24-hour salt lives, unlinkable once it is destroyed" — and see
[identity.md](identity.md) for why that distinction is worth being precise about.

### "GDPR-certified", "CNIL-approved", "ICO-approved"

No such certification exists for this category. CNIL's tool is explicitly a
**self**-evaluation and states that it does not assess overall compliance.
Claiming otherwise is a straightforward misrepresentation.

### "You don't need a DPA with us"

Where we act as a processor for a customer in GDPR or UK GDPR scope, Art.28(3)
requires a written contract. A vendor claiming otherwise, usually on the grounds
that they collect no personal data, is on shaky ground: an IP address reaches
their server like everyone else's and is personal data (*Breyer*, C-582/14).
**Say instead:** point at `/dpa`.

### ...but also not "you always need a DPA"

The inverse overreach, and easier to write by accident because it sounds
conservative. The `/dpa` callout originally said "You do need one of these"
unqualified, which is wrong twice over:

- **Self-hosted installs have no separate processor.** The operator runs the
  software and is the only party handling the data. They need no DPA with us at
  all, only with their own providers.
- **Art.28(3) is a GDPR provision.** Someone with no EU or UK data subjects is
  not bound by it.

Scope the claim: *"if you use the hosted service and GDPR or UK GDPR applies to
you."* Being conservative is not the same as being accurate, and a document that
overstates an obligation is as much a credibility problem as one that
understates it.

### "CCPA compliant"

Vague and unverifiable. **Say instead** what is actually true and checkable: we
do not sell personal information, we do not share it for cross-context
behavioural advertising, and for customer measurement data we act as a service
provider. Under §1798.140(ah) we structurally could not do cross-context
behavioural advertising: the identifier is site-scoped and expires daily.

### "Unlimited data retention" or silence about retention

Retention is a compliance control. State the default (12 months for raw events),
say it is configurable per account, and say what enforces it.

## Also avoid

- **Claiming a size the tracker does not have.** State measured numbers. The
  current script is 7,663 bytes raw, 3,190 gzipped, 2,508 brotli. If you change
  the script, re-measure.
- **Implying cross-day unique visitors.** The identifier rotates daily. A 30-day
  "unique visitors" figure is the sum of 30 daily figures. Label it accurately
  and explain it once, prominently.
- **Comparing favourably to Google Analytics on "accuracy".** Our numbers are a
  good estimate, not a census, for the reasons in
  [identity.md](identity.md#a-known-limitation-stated-plainly). Overclaiming here
  invites a customer to discover the NAT and network-switching caveats on their
  own, which is much worse than being told.
- **"Privacy-friendly" as a substitute for specifics.** It means nothing. Name
  the property.

## Things we can say without qualification

All of these are true, checkable in the source, and covered by specs:

- Tastatur sets no cookies and reads none.
- Nothing is written to the visitor's device: no localStorage, no sessionStorage,
  no IndexedDB, no cache abuse.
- No fingerprinting: no canvas, WebGL, font, audio, plugin, battery or hardware
  probing. The complete list of transmitted fields is `payload()` in
  `public/t.js`, served unminified.
- The visitor identifier is scoped to a single site and to a single 24-hour
  window.
- Do Not Track and Global Privacy Control are honoured by default.
- Raw IP addresses and user-agent strings are never persisted.
- Geography is resolved to country only. No region, city or coordinates.
- Breakdown rows below a configurable distinct-visitor threshold are withheld,
  with complementary suppression so a single hidden row cannot be recovered by
  subtraction.
- Customer data is never pooled across accounts and is never used for our own
  purposes, including product analytics, benchmarking or model training.
- The whole thing is AGPL-3.0, so any of the above can be verified rather than
  taken on trust.

## Roles

For measurement data the **site owner is the controller** and **Tastatur is the
processor**. For account data (email, team membership, billing) Tastatur is the
controller. State both; the split matters because joint controllership can arise
where a provider determines purposes and derives its own benefit from the data
(*Wirtschaftsakademie* C-210/16, *Fashion ID* C-40/17). The operating commitments
in `/dpa` — no cross-account pooling, no reuse for our own purposes — exist
specifically so that does not happen, and they are enforced in code, not only in
the contract.
