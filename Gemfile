source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
# Use Redis adapter to run Action Cable in production
# gem "redis", ">= 4.0.1"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.0"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end
gem "devise"
gem "pundit"
gem "stripe"
gem "sidekiq"
gem "sidekiq-cron"
gem "redis", ">= 5.0"
gem "connection_pool"
gem "rack-cors"
gem "rack-attack"
gem "pagy"
gem "oj"
gem "alba"
gem "dry-monads"
gem "dry-validation"
gem "dry-struct"
gem "dry-types"
gem "resend"
gem "sentry-ruby"
gem "sentry-rails"
gem "lograge"

# --- Analytics ingest --------------------------------------------------------

# Password digests for password-protected shared dashboards. Devise pulls
# bcrypt in transitively, but has_secure_password is our own use of it.
gem "bcrypt", "~> 3.1"

# User-agent parsing. A Ruby port of Matomo's device detector — the same
# database Matomo and Plausible rely on, which matters most for its bot list:
# unfiltered crawler traffic is the single biggest source of wrong numbers in
# self-hosted analytics. LGPL-3.0, compatible with our AGPL-3.0 licence.
gem "device_detector"

# Country-level IP geolocation, reading a local MaxMind-format database.
# Apache-2.0. The database file itself is NOT bundled — see
# `rails tastatur:geoip:download` and docs/self-hosting/geolocation.md.
gem "maxmind-db"

# ISO-3166 country names, so a breakdown reads "Germany" rather than "DE".
# MIT. Data is maintained upstream rather than as a table we would let rot.
gem "countries"

group :development, :test do
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "faker"
  gem "dotenv-rails"
end

group :development do
  gem "letter_opener"
  gem "bullet"
end

group :test do
  gem "shoulda-matchers"
  gem "simplecov", require: false
end
