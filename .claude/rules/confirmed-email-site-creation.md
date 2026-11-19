---
paths:
  - "app/policies/site_policy.rb"
  - "app/controllers/sites_controller.rb"
  - "spec/policies/site_policy_spec.rb"
  - "spec/requests/site_confirmation_spec.rb"
---

### 16. A confirmed email address is required to create a site

`SitePolicy#create?` requires `user.confirmed?` as well as the role. Today that is
unreachable through the sign-in form — `allow_unconfirmed_access_for` is `0.days`, so
an unconfirmed user cannot hold a session at all — and that is precisely why it is
written down rather than left implicit. Relaxing that setting so new users can look
around before confirming is an ordinary thing to want, and it would otherwise hand
site creation to anybody who can type an address they do not own. A site mints a
public token and starts accepting traffic from somebody else's website; that is an
obligation, and obligations need a proven address.

Reading and deleting are deliberately NOT gated. Confirmation is a precondition for
taking something on, not for looking at what you already have, and least of all for
getting out.

`SitesController` explains the refusal before the policy delivers it, because "You do
not have access to that" reads like a permissions problem to ask an admin about. Note
also that `sites#index` only redirects an empty account to the form when the viewer
could actually use it: without that guard the form refuses, `deny_access` redirects
back via the referer, and the two bounce forever.
