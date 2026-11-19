---
paths:
  - "db/seeds.rb"
  - "spec/db/seeds_spec.rb"
  - "app/lib/passwords/deny_list.rb"
---

## Seeded users (development)

- `admin@example.com` / `tastatur-dev-login` — admin (can access `/sidekiq`)
- `user@example.com`  / `tastatur-dev-login` — regular user
- Override with `SEED_PASSWORD`. It is no longer `password`: that string is on
  `config/common_passwords.txt`, which `User` now refuses (`Passwords::DenyList`),
  so seeds using it would raise on a fresh database. Seeds exempt from the
  application's own password rules would be seeds proving those rules apply to
  nobody.
- Plus 5 random Faker users in development

Seeds are idempotent — re-running `db:seed` is safe.
