---
paths:
  - "app/policies/**/*.rb"
  - "spec/policies/**/*.rb"
  - "app/values/authorization_context.rb"
  - "app/controllers/**/*.rb"
---

### 11. Authorization takes a context, not a user

Policies receive an `AuthorizationContext` carrying both the user **and** the
account they are currently acting as. A user can belong to several accounts with
different roles; a policy handed only a `User` would have to re-derive the
account, and that is the step that gets forgotten in one policy out of twelve and
becomes a cross-tenant leak.

`ApplicationPolicy::Scope#resolve` returns `scope.none`, not `scope.all`. A
subclass that forgets to override it shows an empty page — a bug someone reports
— rather than every tenant's data.

Callbacks use `if:`/`unless:` predicates rather than `only: :index`. Since Rails
7.1, naming an action in `only:` that the controller does not define raises, so
`only: :index` breaks every controller without an index action.
