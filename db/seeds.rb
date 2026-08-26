# Idempotent seeds. Safe to run multiple times.
#
# THESE MUST NEVER RUN IN PRODUCTION.
#
# They create admin@example.com / tastatur-dev-login with admin = true, and this is an
# open-source project, so those credentials are public knowledge. `bin/rails
# db:prepare` seeds a database it has just created, and `bin/docker-entrypoint`
# runs `db:prepare` on boot — so every fresh production deployment used to come up
# with a publicly known administrator account that could reach /sidekiq. Verified
# by seeding an empty database with RAILS_ENV=production: both users were created.
#
# Two independent guards now, because one of them being edited away should not be
# enough to reintroduce that:
#
#   1. the environment check below, and
#   2. `seeds: false` on the production database in config/database.yml, which
#      makes ActiveRecord::Tasks::DatabaseTasks.prepare_all skip seeding entirely.
#
# A self-hosted instance gets its first administrator from the first-run setup
# wizard instead, where the operator chooses the password. See
# Tastatur.needs_first_run_setup?
unless Rails.env.local?
  warn <<~MESSAGE
    Refusing to seed in #{Rails.env}.

    db/seeds.rb creates well-known demo credentials and is for development and
    test only. A fresh install creates its first administrator through the
    first-run setup wizard at /, where you choose the password.
  MESSAGE

  exit 0
end

require "faker"

def upsert_user!(email:, password:, name:, admin: false)
  user = User.find_or_initialize_by(email: email)
  user.password = password
  user.password_confirmation = password
  user.name = name
  user.admin = admin
  user.confirmed_at ||= Time.current if user.respond_to?(:confirmed_at)
  user.save!
  puts "  seeded #{user.admin? ? 'admin' : 'user '} #{user.email}"
  user
end

puts "Seeding users..."
# NOT "password" any more, and not because somebody was being fussy: it is on
# config/common_passwords.txt, so `User` now refuses it (see
# Passwords::DenyList) and `save!` here would raise on a fresh database. Seeds
# that had to opt out of the application's own password policy would be seeds
# that prove it does not apply to anybody.
#
# One value, shared by every seeded account, still printed in the output below
# and still documented in CLAUDE.md. These users exist only in development.
SEED_PASSWORD = ENV.fetch("SEED_PASSWORD", "tastatur-dev-login")

upsert_user!(email: "admin@example.com", password: SEED_PASSWORD, name: "Admin User", admin: true)
upsert_user!(email: "user@example.com",  password: SEED_PASSWORD, name: "Regular User")

if Rails.env.development?
  5.times do
    upsert_user!(
      email: Faker::Internet.unique.email,
      password: SEED_PASSWORD,
      name: Faker::Name.name
    )
  end
end

puts "Done. Total users: #{User.count}"
