require "resend"
require "resend/mailer"
require_relative "../../lib/mail_delivery/logged"

Resend.api_key = ENV["RESEND_API_KEY"]

# Register both, and let the environment decide which is used.
ActionMailer::Base.add_delivery_method :resend, Resend::Mailer
ActionMailer::Base.add_delivery_method :logged, MailDelivery::Logged

# Degrade instead of raising when no mail provider is configured.
#
# `production.rb` asks for `:resend` with `raise_delivery_errors = true`. With the
# API key blank, that combination did not merely fail to send mail — it made the
# instance impossible to sign up to, permanently. Measured on a production boot:
#
#   User#save! raised Resend::Error::InvalidRequestError: API key is invalid,
#   the account persisted anyway (Devise confirms from an after_commit hook),
#   unconfirmed and unable to sign in, with its address taken and unreusable.
#
# A self-hosted instance very often has no mail provider on first boot, and the
# person hitting this is the operator setting it up. Writing their confirmation
# link to the log is not elegant, but it is recoverable. A 500 and a dead account
# is not.
if Rails.env.production? && ENV["RESEND_API_KEY"].blank?
  # Assigned on the class, not via `config.action_mailer.delivery_method`.
  # Environment files are evaluated before config/initializers, and the ActionMailer
  # railtie has already copied that config onto ActionMailer::Base by the time this
  # runs — so setting the config here changes nothing at all. Verified: the warning
  # below printed while delivery_method was still :resend.
  ActionMailer::Base.delivery_method = :logged

  Rails.application.config.after_initialize do
    Rails.logger.warn(
      "[tastatur] RESEND_API_KEY is not set. Email is written to this log instead of being " \
      "sent, so confirmation and password-reset links appear in it in plain text. That is the " \
      "only way to finish signing up without a mail provider, but it does mean anyone who can " \
      "read these logs can use those links. Set RESEND_API_KEY to send mail properly. " \
      "See docs/self-hosting/configuration.md"
    )
  end
end
