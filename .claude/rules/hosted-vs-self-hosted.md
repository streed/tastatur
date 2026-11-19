---
paths:
  - "config/initializers/tastatur.rb"
  - "config/routes.rb"
  - "app/controllers/marketing/**/*.rb"
  - "app/views/marketing/**/*"
  - "app/services/seo/**/*.rb"
  - "app/views/layouts/application.html.erb"
---

### 20. One repository, and what `SELF_HOSTED=1` takes away

Everything is in this repository: the product, and the marketing site and waitlist
that sell the hosted service. There used to be a second, private repository holding
the last two, loaded as a Rails engine. It is gone. Do not reintroduce a second
repository, an engine, or a loader for "private" code — a private file committed to
this history stays in it, so anything that must stay private does not belong here at
all.

What survives of the old split is a **property of the deployment**, not of the
checkout. A self-hoster running this on their own hardware sets `SELF_HOSTED=1`, and
two predicates in `config/initializers/tastatur.rb` follow from it:

| | true when | what it gates |
|---|---|---|
| `Tastatur.marketing_site?` | not self-hosted | `/`, `/about`, `/pricing`, `/faq`, `/revenue`, `/llms.txt`, `/index.md` and the waitlist routes, which are behind a route constraint and answer 404 otherwise; the nav and footer links; the marketing entries in the sitemap |
| `Tastatur.waitlist_enabled?` | not self-hosted | the waitlist form, and the wording of the "signups are closed" refusal |

The test for whether something is gated is the one the split used: **would a
self-hoster be worse off without it?** If yes, it is not gated. That is why billing,
revenue attribution and the compliance pages are always present, and only the pages
that sell *our* deployment, and the one table holding addresses of people who are not
users, answer to the predicates. A self-hosted install holds no such addresses,
which is the stronger claim and the one `/privacy` makes.

Consequences worth knowing:

- **`/` has two owners.** The marketing home is routed first behind the constraint;
  `root to: "pages#home"` sits after it and is what a self-hosted instance reaches
  (a forward to sign-in, or to the site list). Both are `root_path`. The marketing
  route is `as: nil` because Rails refuses a second route named `root`.
- **A view guards on the predicate before linking to a marketing page.** The route
  helpers exist everywhere now, but on a self-hosted instance the routes 404, so an
  unguarded link is a dead one.
- **Self-hosted also means the setup wizard.** `needs_first_run_setup?` is
  `self_hosted? && !User.exists?`, and the wizard wins over the page being asked
  for. A spec that stubs `self_hosted?` for a route must stub
  `needs_first_run_setup?` as well, or it lands on `/setup`.
- **Migrations are one ordinary sequence.** There is still no schema file (§8), so
  versions must be unique, and a new one takes the date it is written. (Two older
  versions, `20260803130000` and `20260803140000`, are already recorded in some
  local databases — check `schema_migrations` before reusing a number in that range.)
