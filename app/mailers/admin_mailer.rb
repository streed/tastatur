class AdminMailer < ApplicationMailer
  # A new person signed up.
  #
  # Addressed to one administrator at a time rather than BCC'ing them all,
  # because a shared recipient list in a header is a small leak of who runs the
  # instance, and because ActionMailer previews and deliveries are easier to
  # reason about one at a time.
  def new_signup(admin:, user:)
    @admin = admin
    @user = user
    @account = user.default_account
    @signed_up_at = user.created_at

    mail to: admin.email, subject: "New signup: #{user.email}"
  end
end
