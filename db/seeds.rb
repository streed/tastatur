# Idempotent seeds. Safe to run multiple times.
# Credentials below were captured during `rails new` from template prompts.

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
upsert_user!(email: "admin@example.com", password: "password", name: "Admin User", admin: true)
upsert_user!(email: "user@example.com",  password: "password", name: "Regular User")

if Rails.env.development?
  5.times do
    upsert_user!(
      email: Faker::Internet.unique.email,
      password: "password",
      name: Faker::Name.name
    )
  end
end

puts "Done. Total users: #{User.count}"
