module TwoFactor
  # Turns the second factor on for one person.
  #
  # WHY THERE IS NO ENROLMENT CHALLENGE. The usual shape of this — send a code,
  # make them type it, and only then switch it on — exists to prove the mailbox
  # actually receives mail before locking the account behind it. Here that proof
  # already happened: :confirmable refuses sign-in until the address is confirmed
  # (`allow_unconfirmed_access_for = 0.days`), so nobody can reach this screen
  # without having clicked a link sent to it. Asking again would be ceremony that
  # verifies a fact already on the record, and the `confirmed?` guard below is
  # what keeps that argument true rather than assumed.
  #
  # The residual risk is a mailbox that worked at confirmation and does not now.
  # That is why an instance administrator can turn this back off from the admin
  # console — see Admin::UsersController#disable_two_factor. Without that lever
  # the only remedy would be a database console.
  class Enable < ApplicationService
    def initialize(user:)
      @user = user
    end

    def call
      return Failure(:already_enabled) if @user.two_factor_enabled?
      return Failure(:unconfirmed) unless @user.confirmed?

      @user.update!(two_factor_enabled: true)

      Success(@user)
    end
  end
end
