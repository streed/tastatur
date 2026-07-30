module Accounts
  # Adds someone to an account, creating their user record if they are new.
  #
  # A new invitee gets a random password and a Devise reset token rather than a
  # password chosen by whoever invited them — an inviter must never know or set
  # another person's credentials.
  class InviteMember < ApplicationService
    def initialize(account:, email:, role: "member", invited_by: nil)
      @account = account
      @email = email.to_s.strip.downcase
      @role = role.presence || "member"
      @invited_by = invited_by
    end

    def call
      return Failure(:blank_email) if @email.blank?
      return Failure(:invalid_role) unless Membership::ROLES.include?(@role)

      user = User.find_by(email: @email)
      return Failure(:already_a_member) if user && user.member_of?(@account)

      membership = nil
      reset_token = nil

      ActiveRecord::Base.transaction do
        if user.nil?
          user, reset_token = create_invited_user
        end
        membership = Membership.create!(account: @account, user: user, role: @role)
      end

      # After the transaction, so a delivery failure cannot roll back a membership
      # that was successfully created.
      notify(membership, reset_token)

      Success(membership)
    rescue ActiveRecord::RecordInvalid => e
      Failure(e.record.errors.full_messages.to_sentence)
    end

    private

    # An invited user is created already confirmed, and gets a password-reset
    # email instead of a confirmation email.
    #
    # WHY, because `skip_confirmation!` looks like a shortcut past a security
    # control and is not:
    #
    #   The account is unusable until they click the emailed reset link, because
    #   the password above is 32 random characters that nobody, including us,
    #   ever sees. Clicking a link sent to that address IS proof they control it,
    #   which is the only thing confirmation establishes. A separate confirmation
    #   step would verify the same fact twice.
    #
    # The alternative was worse and is what this replaced:
    # `skip_confirmation_notification!` suppresses the confirmation email without
    # confirming the user, so an invited person could set a password via the
    # reset link and then still be refused at sign-in, with no confirmation email
    # ever sent and no way out. They were permanently locked out of an account
    # they had been invited to.
    # Returns the user and the raw reset token.
    #
    # `set_reset_password_token` rather than `send_reset_password_instructions`,
    # because the bare Devise reset email is the wrong message here: out of context
    # it reads as "somebody tried to reset my password", and it never says who
    # invited them or to what. The token is the same; only the envelope changes.
    def create_invited_user
      user = User.new(email: @email, password: SecureRandom.base58(32))
      user.skip_confirmation!
      user.save!

      [user, user.send(:set_reset_password_token)]
    end

    # An existing user gets one too. Previously they got nothing at all: their site
    # list quietly grew and they were left to notice on their own.
    def notify(membership, reset_token)
      MemberInvitationMailer
        .invited(membership, invited_by: @invited_by, reset_token: reset_token)
        .deliver_later
    rescue StandardError => e
      # The membership is real and the person can be told again. Failing the whole
      # invitation because mail is down would be the worse outcome.
      Rails.logger.error("[tastatur] invitation email failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end
  end
end
