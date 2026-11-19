---
paths:
  - "app/services/two_factor/**/*.rb"
  - "app/lib/two_factor/**/*.rb"
  - "app/values/two_factor/**/*.rb"
  - "app/controllers/two_factor/**/*.rb"
  - "app/controllers/users/**/*.rb"
  - "app/models/trusted_device.rb"
  - "app/models/two_factor_challenge.rb"
  - "app/views/two_factor/**/*.erb"
  - "app/views/two_factor_mailer/**/*.erb"
  - "spec/requests/two_factor_spec.rb"
  - "spec/requests/auth_funnel_spec.rb"
  - "spec/services/two_factor/**/*.rb"
---

### 15. Two-factor authentication, and why sign-in is two controllers

Optional, per user, by emailed six-digit code. `TwoFactor::IssueChallenge` owns the
code's length, lifetime, attempt budget and resend interval; nothing else may decide
any of those. The rules an agent must not break:

- **A correct password must not produce a session of any kind.** This is the whole
  design and the one thing that looks over-engineered until you know why. The obvious
  implementation — let Warden sign the user in, then block every request with a
  `before_action` until the code is entered — is wrong *here*, because `/sidekiq` is
  mounted behind `authenticate :user, ->(u) { u.admin? }` inside `config/routes.rb`.
  That is a Warden check no ApplicationController callback can reach, so a "signed in
  but gated" session would walk a stolen admin password into the job console. So
  `Users::SessionsController` tears the session down and leaves only
  `TwoFactor::PendingSignIn`, which authorizes nothing.
- **The pending marker carries `authenticatable_salt`**, compared on the way out for
  the same reason Devise carries it in a real session: a password reset performed
  *because* the password was stolen must invalidate a sign-in already in flight.
- **Devise's trackable is suppressed on the password request and re-run explicitly**
  at the point sign-in actually completes (`devise.skip_trackable`). Otherwise a
  correct password followed by an abandoned challenge is recorded as a sign-in — in
  the very field a customer reads when working out whether they have been broken
  into. The same request's `after_authentication` hook records the "Signed In" funnel
  step and reads `sign_in_count` *before* trackable increments it, so if you move
  either one, move both and re-read `spec/requests/auth_funnel_spec.rb`.
- **A trusted device is a receipt, not a bypass.** `TwoFactor::TrustDevice` is only
  ever called after a challenge has been answered. The row holds a SHA-256 digest —
  deliberately not bcrypt, because the token is 32 random bytes with no keyspace to
  grind and the digest is a lookup key. Check `device.user_id` against the person
  signing in; a cookie is not a bearer of somebody else's trust.
- **Switching two-factor off destroys every trusted device** (`TwoFactor::Disable`),
  or they come back to life when it is switched on again months later.
- **No user-agent, IP or location on the device list.** Every comparable product puts
  them there and they would genuinely help; §13 is why we do not, and
  `spec/privacy_invariants_spec.rb` fails the migration that adds one.
- **An instance administrator can turn it OFF and must never be able to turn it ON.**
  The off switch is the remedy for a mailbox that stopped working; an on switch would
  let an operator aim a customer's codes at an address they control. There is no
  route, no policy predicate and no controller action for the second.
- **The code email contains nothing to click.** An email that trains people to follow
  a link to a sign-in page trains them to follow somebody else's, and a one-time code
  is what a phishing page is for. A spec pins the set of links to the two the shared
  layout gives every email.
