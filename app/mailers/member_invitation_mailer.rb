class MemberInvitationMailer < ApplicationMailer
  # "You have been added to an account."
  #
  # Two cases were previously handled badly and not at all:
  #
  #   A NEW invitee got Devise's bare password-reset email. Out of context that
  #   reads as "someone tried to reset my password", which is alarming rather than
  #   welcoming, and it never says who invited them or to what.
  #
  #   An EXISTING user added to an account got nothing whatsoever. Their sites list
  #   silently grew and they were expected to notice.
  #
  # The reset link is included for the first case, because it is genuinely what they
  # need — an invited user is created with 32 random characters nobody has ever
  # seen, so setting a password is the only way in. See Accounts::InviteMember for
  # why that is confirmation enough on its own.
  def invited(membership, invited_by:, reset_token: nil)
    @membership = membership
    @account = membership.account
    @user = membership.user
    @invited_by = invited_by
    @role = membership.role
    @new_account = reset_token.present?

    # `edit_user_password_url`, not `edit_password_url`. The latter is a scoped
    # helper that Devise::Mailers::Helpers mixes into Devise's own mailers, and this
    # is not one of them — calling it here raises NoMethodError at render time,
    # which is to say when the first person is invited rather than when the code is
    # written.
    @action_url =
      if reset_token
        edit_user_password_url(reset_password_token: reset_token)
      else
        Tastatur.base_url
      end

    mail(
      to: @user.email,
      subject: "#{inviter_name} added you to #{@account.name} on Tastatur"
    )
  end

  private

  # Falls back to the email, then to something neutral. An invitation that says
  # "someone added you" is still better than one that says "added you".
  def inviter_name
    @invited_by&.name.presence || @invited_by&.email.presence || "Someone"
  end
  helper_method :inviter_name
end
