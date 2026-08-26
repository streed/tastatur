module Onboarding
  # Creates the owner, their account, and their first site in one transaction.
  #
  # Used only by the self-hosted first-run wizard. The user is created already
  # confirmed: Devise's :confirmable would otherwise send an email through a
  # mailer the operator has almost certainly not configured yet, and lock them
  # out of the instance they just installed.
  class FirstRunSetup < ApplicationService
    def initialize(user_params:, site_params:)
      @user_params = user_params
      @site_params = site_params
    end

    # A Postgres advisory lock, held for the transaction and released with it.
    #
    # Arbitrary constant, chosen once and never derived from anything, so two
    # processes always ask for the SAME lock.
    SETUP_LOCK = 7_017_930_581

    def call
      user = User.new(@user_params.merge(confirmed_at: Time.current, admin: true))
      site = Site.new(@site_params)

      ActiveRecord::Base.transaction do
        # THE CHECK THE CONTROLLER ALREADY DID, DONE AGAIN INSIDE THE LOCK.
        #
        # FirstRunController refuses unless `Tastatur.needs_first_run_setup?`,
        # which is `self_hosted? && !User.exists?`. That is a read in a
        # before_action and a write several milliseconds later, so two requests
        # arriving together both saw an empty table and both created a confirmed
        # INSTANCE ADMINISTRATOR — the account that can reach /sidekiq.
        #
        # The window is one deploy long and needs somebody to reach the box
        # before its operator does, which is why this is cheap insurance rather
        # than an emergency. It is also the only moment in this application's
        # life when an unauthenticated stranger can mint an admin, so the
        # cheapness is the argument for doing it rather than against.
        #
        # An advisory lock rather than a unique index on `admin`: the instance
        # is meant to be able to have several administrators later, so the
        # constraint is on the RACE, not on the shape of the data. `pg_advisory_
        # xact_lock` blocks rather than failing, so the loser waits, re-reads,
        # and finds the table no longer empty.
        # `execute`, not `select_value`: the function returns void, and asking
        # for its value makes the adapter log "unknown OID 2278" on every first
        # run. Nothing reads the result — the lock is the point.
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_xact_lock(?)", SETUP_LOCK])
        )
        return Failure(:already_set_up) unless Tastatur.needs_first_run_setup?

        raise ActiveRecord::Rollback unless user.save

        account = ProvisionAccount.call(user: user, name: default_account_name).value_or(nil)
        raise ActiveRecord::Rollback if account.nil?

        site.account = account
        raise ActiveRecord::Rollback unless site.save
      end

      return Failure(user: user, site: site) unless user.persisted? && site.persisted?

      Success(user)
    end

    private

    def default_account_name
      host = @site_params[:domain].to_s.split(".").first.presence
      host ? host.capitalize : "My account"
    end
  end
end
