---
paths:
  - "app/helpers/tastatur_form_builder.rb"
  - "app/views/**/*.erb"
  - "app/javascript/controllers/**/*.js"
  - "spec/requests/destructive_buttons_spec.rb"
  - "spec/requests/value_picker_spec.rb"
  - "app/services/analytics/known_values.rb"
---

### 9. One form pattern, and the builder enforces it

`TastaturFormBuilder` is the application's default form builder, which means it
applies to Devise's views too. Every field is a micro-label, a control and an
optional hint, in that order, with the same spacing:

```erb
<%= form_with model: @site, class: "card card-body space-y-6" do |f| %>
  <%= f.error_summary %>
  <%= f.field :domain, "Domain", hint: "Just the hostname." %>
  <%= f.field :timezone, "Timezone", as: :select, choices: zones %>
  <%= f.actions "Save", cancel_to: sites_path %>
<% end %>
```

Do not hand-roll `<input>` or `<label>` markup. A form whose object is not an
ActiveRecord model still gets the builder — give it an `ActiveModel` form object
(see `MemberInvitation`) rather than dropping to raw HTML, which is how a
codebase ends up with four subtly different forms.

**A `button_to` must never be rendered inside a form,** and `f.actions` takes
`destroy_to:` — a URL — rather than a rendered button so that it cannot be. This
is not tidiness. `button_to` emits a `<form>`, so passing one in nested a form
inside a form; that is invalid HTML and the parser **discards the inner start
tag**, which leaves the delete button owned by the surrounding edit form and its
`data-turbo-confirm` attached to an element that no longer exists. Every delete
button on every edit screen therefore ran `update`: measured on the wire, Turbo
sent `_method=patch`, the record was SAVED, and the redirect landed back on it
looking like nothing had happened. Nothing raises, nothing logs, and no request
spec can catch it, because a request spec issues the clean DELETE that no
browser was ever going to send — `spec/requests/destructive_buttons_spec.rb`
scans the delivered markup instead. The builder emits the delete form into
`content_for(:detached_forms)`, which the layout yields outside every other
form, and associates the button with it by the HTML `form` attribute. The one
place `destroy_to:` still may not be used is a form rendered into a turbo frame:
Turbo extracts the frame and drops the rest, taking the detached form with it.

**`as: :combobox` is a text field that can also be picked from,** and everything
it is used for is one shape: a string the customer's own website produced,
compared against a column. The match value of a goal or a funnel step, the value
of a saved dashboard filter, and the page or event the Journeys screen opens on.
A typo saves cleanly and then reports 0% forever, which is indistinguishable
from a page nobody converts on. Two halves that must both stay as they are:

- **It stays free text.** A `<select>` would refuse a goal for a page that has
  not shipped yet, and refuse `/blog/**` outright — a wildcard is a pattern, so
  it will never appear in a list of things that happened.
- **The options it offers are a breakdown, so §13's threshold applies.**
  `Analytics::KnownValues` goes through `Analytics::Breakdown` for exactly that
  reason. Replacing it with a cheaper `SELECT DISTINCT path` would publish, in a
  form, the rows the Top pages panel withholds. The visible consequence is that a
  quiet site's picker is empty; the forms say so, in the same voice
  `spec/requests/breakdown_suppression_spec.rb` pins for the dashboard, rather
  than looking broken.

The picker needs the `kind` control and the field inside one
`data-controller="value-picker"` element, and one payload per page rather than
one per field — see `OffersKnownValues`, which is a `helper_method` and not a
`before_action` so a save that redirects never pays for the scan.

**`nested-form` nests inside itself, and two things make that work.** The funnel
form is a list of steps, each of which is a list of alternatives that satisfy it
(§12). Stimulus scopes targets and actions to the *nearest* controller of an
identifier, so the outer list does not steal the inner one's `<template>` — but
anything that walks the DOM itself must filter by `closest('[data-controller~=
"nested-form"]') === this.element`, or a step's alternatives are counted as steps.
And the two levels need **different template placeholders**
(`data-nested-form-placeholder-value`): the outer Add replaces its own throughout
the markup it clones, and would consume the inner one on the way past, leaving
every later alternative added to that step under the same param key.
