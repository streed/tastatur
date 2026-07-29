class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "no-reply@example.com")
  default from: "from@example.com"
  layout "mailer"
end
