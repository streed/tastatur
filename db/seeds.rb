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

# `in Success(...) / in Failure(...)` below needs the constants in scope.
# ApplicationController includes this for every controller; a seeds script is
# not one, and without it the pattern match fails with "uninitialized constant
# Success" at the point the first account is provisioned.
include Dry::Monads[:result]

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

# TOPS UP TO FIVE rather than adding five, which is what the promise at the top
# of this file requires. `Faker::Internet.unique.email` returns an address that
# has not been seen before, so `upsert_user!` never matched an existing row and
# every `db:seed` grew the table by five — a file headed "Idempotent seeds. Safe
# to run multiple times" that was not, in the one block where nobody would look.
#
# Counted by subtracting the two named accounts rather than by tagging the
# generated ones: a tag would be a column, and this is scenery.
FAKER_USER_TARGET = 5

if Rails.env.development?
  existing = User.where.not(email: %w[admin@example.com user@example.com]).count

  [FAKER_USER_TARGET - existing, 0].max.times do
    upsert_user!(
      email: Faker::Internet.unique.email,
      password: SEED_PASSWORD,
      name: Faker::Name.name
    )
  end
end

# --- Accounts and a site ------------------------------------------------------
#
# WITHOUT THIS THE SEEDED USERS CANNOT USE HALF THE APPLICATION, which was not
# obvious until a database was rebuilt from scratch and the documented admin
# login answered 404 on /account.
#
# `upsert_user!` above writes a User row and stops there. An account is created
# by Onboarding::ProvisionAccount, which runs in Users::RegistrationsController
# — a path seeds never take. So a seeded user has no membership,
# `current_account` is nil, and AccountsController raises RecordNotFound.
# Everything hanging off an account (settings, members, billing, sites, the
# dashboard) is unreachable, and the failure reads like a bug in the app rather
# than an omission in the fixtures.
#
# THE SERVICE IS CALLED RATHER THAN COPIED. Seeds that build an account and a
# membership by hand are a second definition of what provisioning means, and it
# is the copy that drifts — a role, a plan default or a future side effect added
# in one place and not the other. `:already_provisioned` is the ordinary answer
# on a re-run and is not an error, which is what keeps these seeds idempotent.
puts "Provisioning accounts..."
User.find_each do |user|
  case Onboarding::ProvisionAccount.call(user: user)
  in Success(account) then puts "  #{user.email} owns #{account.name}"
  in Failure(:already_provisioned) then nil
  in Failure(reason) then warn "  could not provision for #{user.email}: #{reason.inspect}"
  end
end

# One site on the admin's account, so the dashboard, the installation snippet and
# every screen nested under /sites/:token are reachable immediately. Found by
# domain rather than created blindly, for the same reason as the users above.
admin = User.find_by(email: "admin@example.com")
if admin && (account = admin.default_account)
  site = account.sites.find_or_initialize_by(domain: "example.com")

  if site.new_record?
    site.timezone = "Etc/UTC"
    site.k_anonymity_threshold = 0
    site.save!
    puts "Seeded site example.com (#{site.public_token})"
  else
    puts "Site example.com already present (#{site.public_token})"
  end
end

puts "Done. #{User.count} users, #{Account.count} accounts, #{Site.count} sites."
