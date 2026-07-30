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

    def call
      user = User.new(@user_params.merge(confirmed_at: Time.current, admin: true))
      site = Site.new(@site_params)

      ActiveRecord::Base.transaction do
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
