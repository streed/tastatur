# Themed email previews, at /rails/mailers in development.
#
# Email is the hardest surface to check by hand: you cannot see it without
# triggering a real signup or reset, and by then it has already gone out. These
# render every template against an unsaved User so the theme can be reviewed in
# a browser and in a client, without sending anything.
class DeviseMailerPreview < ActionMailer::Preview
  def confirmation_instructions
    Devise::Mailer.confirmation_instructions(user, "sample-confirmation-token")
  end

  def reset_password_instructions
    Devise::Mailer.reset_password_instructions(user, "sample-reset-token")
  end

  def unlock_instructions
    Devise::Mailer.unlock_instructions(user, "sample-unlock-token")
  end

  def password_change
    Devise::Mailer.password_change(user)
  end

  def email_changed
    Devise::Mailer.email_changed(user)
  end

  private

  # Unsaved on purpose: a preview must never write to the database.
  def user
    User.new(email: "you@example.com", name: "Sample Person").tap do |u|
      u.unconfirmed_email = "new-address@example.com"
    end
  end
end
