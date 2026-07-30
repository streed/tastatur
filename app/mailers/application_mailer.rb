class ApplicationMailer < ActionMailer::Base
  # ONE default from address, read from the environment.
  #
  # The starter template declared `default from:` twice and the second wins, so
  # every production email was sent from "from@example.com" regardless of
  # MAIL_FROM. Resend refuses mail from a domain you have not verified, so this
  # failed at the worst possible moment: the confirmation email a brand-new user
  # is waiting on before they can sign in at all.
  default from: ENV.fetch("MAIL_FROM", "no-reply@localhost")

  layout "mailer"
end
