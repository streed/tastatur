class WaitlistMailer < ApplicationMailer
  # "Confirm you want to hear about this."
  #
  # The only email this list sends until the feature ships, and the only one that
  # can be triggered by an unauthenticated stranger — which is why Waitlist::Join
  # holds a resend cooldown and Rack::Attack throttles the endpoint. Both exist
  # to stop this being a button that delivers our mail to somebody else.
  #
  # Note what the body does NOT do: it never says "you signed up". Whoever
  # receives it may not have, and telling them they did is how a product ends up
  # arguing with someone about an action they did not take. It says an address
  # was entered, and that nothing happens unless they click.
  def confirm(signup, token:)
    @signup = signup
    @confirm_url = confirm_waitlist_url(token: token)
    @feature_name = FEATURE_NAMES.fetch(signup.feature)

    mail(to: signup.email, subject: "Confirm your place on the #{@feature_name} list")
  end

  # What a feature is called in a sentence. In the mailer rather than on the
  # model because it is copy, and the model has no business holding copy.
  FEATURE_NAMES = { "revenue_attribution" => "Tastatur revenue attribution" }.freeze
end
