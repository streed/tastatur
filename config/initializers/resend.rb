require "resend"

Resend.api_key = ENV["RESEND_API_KEY"]

# Register Resend as an ActionMailer delivery method.
require "resend/mailer"
ActionMailer::Base.add_delivery_method :resend, Resend::Mailer
