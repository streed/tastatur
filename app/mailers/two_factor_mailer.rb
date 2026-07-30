class TwoFactorMailer < ApplicationMailer
  # The sign-in code.
  #
  # NOTHING TO CLICK. Every other message this application sends is a button you
  # click, and this one deliberately is not: an email that trains people to click
  # through to a sign-in page trains them to click through to somebody else's,
  # and a one-time code is exactly what a phishing page is after. The code is
  # typed into a screen the reader already has open, which is the only shape that
  # survives being forwarded.
  #
  # The shared layout's two footer links are the only anchors in it, and
  # spec/mailers/two_factor_mailer_spec.rb pins that set — so adding a helpful
  # "Open Tastatur" button fails a test rather than quietly undoing the argument
  # above.
  #
  # The subject carries the code so a phone's lock screen answers the question
  # without unlocking. That is a deliberate trade: a notification preview is
  # visible to whoever holds the handset, and somebody holding your unlocked
  # handset has your mailbox anyway.
  def challenge(user, code)
    @user = user
    @code = code
    @expires_in_minutes = (TwoFactor::IssueChallenge::CODE_TTL / 60).to_i

    mail(
      to: user.email,
      subject: "#{code} is your Tastatur sign-in code"
    )
  end
end
