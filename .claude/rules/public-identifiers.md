---
paths:
  - "app/models/**/*.rb"
  - "config/routes.rb"
  - "spec/requests/public_identifiers_spec.rb"
---

### 10. Public identifiers are never primary keys

Nothing routable is addressed by its `id`. Sequential integers in URLs tell
anyone who sees one roughly how many sites and goals exist across the whole
instance, and they make enumeration the obvious first thing to try.

Primary keys stay `bigint` — they index better and keep foreign keys cheap, and
none of that is visible outside the database. Only the routed identifier changes:

| Model | Routed by | Why |
|---|---|---|
| `Site` | `public_token` (16-char Crockford base32) | pasted into a script tag, so short and readable matters |
| `SharedLink` (public URL) | `slug` (24 chars, ~143 bits) | the only thing protecting an unlisted dashboard |
| Everything else | `public_id` (UUID v4) | |

Include `PubliclyIdentified` and declare it:

```ruby
class Goal < ApplicationRecord
  include PubliclyIdentified
  public_identifier                    # defaults to :public_id
end

class Site < ApplicationRecord
  include PubliclyIdentified
  public_identifier :public_token
end
```

**The footgun this concern exists to prevent.** `resources :sites, param:
:public_token` renames the route *segment*, but `site_path(site)` still calls
`to_param`, which defaults to `id`. Every generated link then points at
`/sites/2` while the route expects a token, so **every link 404s** — with no
error at boot and nothing wrong in the routes file. Renaming a route param
without overriding `to_param` is a silent, total break, and a spec that builds
paths by hand will not catch it. `spec/requests/public_identifiers_spec.rb`
asserts on the URLs the app *generates* and then follows them, which does.

Look records up with `find_by_public_id!`, never `find`.
