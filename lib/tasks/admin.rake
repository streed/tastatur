# Instance administrators — operators of this installation, which is a different
# thing from being an admin of an account. See Admin::BasePolicy.
#
# The flag is settable from the admin console, but that is circular on a fresh
# instance: somebody has to be an administrator before anyone can be made one.
# These tasks are the way in.
namespace :tastatur do
  namespace :admin do
    desc "Grant instance admin to a user by email"
    task :grant, [:email] => :environment do |_task, args|
      email = args[:email].to_s.strip.downcase
      abort "Usage: rails 'tastatur:admin:grant[someone@example.com]'" if email.blank?

      user = User.find_by(email: email)
      abort "No user with email #{email}." if user.nil?

      if user.admin?
        puts "#{user.email} is already an instance administrator."
      else
        user.update!(admin: true)
        puts "#{user.email} is now an instance administrator."
      end
    end

    desc "Revoke instance admin from a user by email"
    task :revoke, [:email] => :environment do |_task, args|
      email = args[:email].to_s.strip.downcase
      abort "Usage: rails 'tastatur:admin:revoke[someone@example.com]'" if email.blank?

      user = User.find_by(email: email)
      abort "No user with email #{email}." if user.nil?
      abort "#{user.email} is not an instance administrator." unless user.admin?

      # The console cannot remove the last administrator either. An instance with
      # none has no way back except a shell on the production container.
      abort "Refusing: #{user.email} is the only administrator." if User.administrators.count <= 1

      user.update!(admin: false)
      puts "#{user.email} is no longer an instance administrator."
    end

    desc "List instance administrators"
    task list: :environment do
      admins = User.administrators.order(:email)

      if admins.empty?
        puts "No instance administrators. Grant one with:"
        puts "  rails 'tastatur:admin:grant[you@example.com]'"
      else
        puts "#{admins.count} instance #{'administrator'.pluralize(admins.count)}:"
        admins.each { |u| puts "  #{u.email}#{' (unconfirmed)' unless u.confirmed?}" }
      end
    end

    # Declarative, and safe to run on every deploy — which is the point.
    #
    # ADMIN_EMAILS is the list of people who should be administrators of this
    # instance. Running this from the deploy means a new environment comes up with
    # the right people already able to get in, rather than needing someone to
    # remember a manual step at the moment they are least likely to.
    #
    # It only ever GRANTS. Revoking from an env var would mean a typo, or a
    # variable that failed to load, silently locking every administrator out of
    # the console — and the console is where you would go to fix it. Revoking
    # stays a deliberate act.
    desc "Grant instance admin to everyone in ADMIN_EMAILS (idempotent; never revokes)"
    task sync: :environment do
      emails = ENV["ADMIN_EMAILS"].to_s.split(/[,\s]+/).map { |e| e.strip.downcase }.reject(&:blank?)

      if emails.empty?
        puts "ADMIN_EMAILS is unset; nothing to do."
        next
      end

      granted, already, missing = [], [], []

      emails.each do |email|
        user = User.find_by(email: email)

        if user.nil?
          missing << email
        elsif user.admin?
          already << email
        else
          user.update!(admin: true)
          granted << email
        end
      end

      puts "Granted:  #{granted.join(', ')}" if granted.any?
      puts "Already:  #{already.join(', ')}" if already.any?
      # Not an error. The usual reason is that the person has not signed up yet,
      # and the next deploy after they do will pick them up.
      puts "No account yet (will be granted on a later run): #{missing.join(', ')}" if missing.any?
    end
  end
end
