---
paths:
  - "config/routes.rb"
---

## Routes provided out of the box

- `/`            — the marketing landing page; on a self-hosted instance, the sign-in form (§12, §20)
- `/dashboard`   — authenticated landing page
- `/up`          — health check (DB + Redis ping), returns JSON
- `/sidekiq`     — Sidekiq web UI, gated on `current_user.admin?`
- Devise routes (`/users/sign_in`, `/users/sign_up`, etc.)
