module Onboarding
  # Gives a newly registered user an account to own.
  #
  # Every user needs exactly one account immediately — without it there is
  # nothing to hang a site off and the dashboard has nowhere to send them. This
  # runs on registration rather than lazily on first use, so `current_account`
  # can stay a plain reader with no side effects.
  class ProvisionAccount < ApplicationService
    def initialize(user:, name: nil)
      @user = user
      @name = name
    end

    def call
      return Failure(:already_provisioned) if @user.accounts.any?

      account = nil

      ActiveRecord::Base.transaction do
        account = Account.create!(
          name: @name.presence || default_name,
          plan: Tastatur.self_hosted? ? "self_hosted" : "free"
        )
        Membership.create!(account: account, user: @user, role: "owner")
      end

      Success(account)
    rescue ActiveRecord::RecordInvalid => e
      Failure(record_invalid: e.message)
    end

    private

    # "sean@reed.pub" -> "Sean's account". Better than "Account 1", and
    # renameable on the account settings screen.
    #
    # Splits on whitespace as well as punctuation: without it, a name like
    # "New Person" produced "New person's account", because only the first
    # character was re-capitalised and the space survived.
    def default_name
      handle = @user.name.presence || @user.email.to_s.split("@").first.to_s
      handle = handle.split(/[\s._-]+/).first.to_s
      handle = handle.presence || "My"
      "#{handle.capitalize}'s account"
    end
  end
end
