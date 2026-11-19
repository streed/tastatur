---
paths:
  - "app/controllers/waitlist_signups_controller.rb"
  - "app/services/waitlist/**/*.rb"
  - "app/models/waitlist_signup.rb"
  - "app/jobs/purge_unconfirmed_waitlist_signups_job.rb"
  - "app/controllers/users/registrations_controller.rb"
  - "app/views/waitlist_signups/**/*"
  - "app/views/compliance/privacy_policy.html.erb"
  - "spec/requests/registration_spec.rb"
---

### 19. The waitlist

`waitlist_signups` holds the addresses kept for the unshipped revenue feature (§18).
It is available where `Tastatur.waitlist_enabled?` (§20), which is to say never on a
self-hosted install: **that deployment holds no addresses for people who are not
users at all**, which is the stronger position and what `/privacy` describes there.
Do not make the waitlist reachable under `SELF_HOSTED=1` to "keep parity". Each rule
below has a spec.

- **A row is not a list member until `confirmed_at` is set.** Anyone can type any
  address into a public form, so an unconfirmed row is a claim, not consent.
  `Waitlist::Join` mails a link and stores nothing else, and
  `PurgeUnconfirmedWaitlistSignupsJob` deletes claims after a week — which the
  confirmation email states, making it a promise rather than housekeeping.
- **Leaving DELETES the row.** No `unsubscribed_at`, no suppression list. The
  industry default keeps the address specifically because its owner asked us not to
  have it, which this product does not get to do. `Waitlist::Leave`'s spec is what
  stops a suppression list being reintroduced as a tidy-up.
- **Unsubscribing is two routes on one path, and confirming is one.** A mail client
  that prefetches links must not be able to delete somebody's place before they
  have seen a word — so `GET /waitlist/leave/:token` is a page with a button and
  only the `DELETE` removes anything.
- **Every outcome of joining looks identical from outside.** `Waitlist::Join`
  distinguishes `:sent`, `:already_confirmed` and `:recently_sent`; the controller
  renders one sentence for all three, because three messages would turn a public
  form into a way of asking whether a named person is on the list.
- **The token is stored as a SHA-256 digest**, for the reason `TrustedDevice`
  gives: 32 random bytes have no keyspace to grind, so the digest is a lookup key
  rather than a password.
- **The address is in the privacy policy's "what we hold about you" table**, on a
  consent basis. A row added to `waitlist_signups` is a row edited in
  `app/views/compliance/privacy_policy.html.erb`, and a table that omitted the one
  place we hold addresses for people who are not customers would make every other
  row in it less believable.
- **`ALLOW_SIGNUP=0` means two different things.** On somebody's own install it
  means the instance is theirs and there is nothing to wait for; on the hosted
  service it means "not yet". `Users::RegistrationsController` picks its refusal
  message with `Tastatur.waitlist_enabled?`.
