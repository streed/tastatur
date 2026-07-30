# The sign-in code email, at /rails/mailers in development.
#
# Worth previewing more than most: the code is set in a monospace stack at 32px
# with wide letter-spacing so 0 and O are distinguishable when read off a phone,
# and that is precisely the kind of styling email clients quietly rewrite. There
# is also nothing to click, which is easier to verify by looking than by reading
# the template.
class TwoFactorMailerPreview < ActionMailer::Preview
  def challenge
    TwoFactorMailer.challenge(user, "042195")
  end

  private

  # Unsaved on purpose: a preview must never write to the database.
  def user
    User.new(email: "you@example.com", name: "Sample Person")
  end
end
