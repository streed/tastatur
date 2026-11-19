module Waitlist
  # Puts an address in the queue for a feature that has not shipped, and mails it
  # a link to prove it wants to be there.
  #
  # DOUBLE OPT-IN, and the reason is not etiquette. This form takes an address
  # from an unauthenticated stranger who does not have to own it. Without a
  # confirmation step the list is a collection of claims, some of which are
  # somebody signing up an address to annoy its owner — and the first time we
  # use the list, that person receives mail they never asked for from a company
  # whose entire argument is data restraint.
  #
  # THE OUTCOMES ARE DISTINCT HERE AND IDENTICAL AT THE CONTROLLER. `:sent`,
  # `:already_confirmed` and `:recently_sent` tell three different stories, and
  # a caller that rendered three different messages would turn this form into a
  # way to ask "is this person on the list", which is a question about somebody
  # else. Devise's `paranoid` mode makes the same trade on password reset.
  class Join < ApplicationService
    def initialize(params:)
      @params = params
    end

    def call
      contract = WaitlistSignupContract.new.call(@params.to_h.symbolize_keys)
      return Failure(validation: contract.errors.to_h) if contract.failure?

      attrs = contract.to_h
      signup = find_or_initialize(attrs)

      return Success(:already_confirmed) if signup.confirmed?
      return Success(:recently_sent) unless signup.resend_allowed?

      issue(signup, attrs)
    end

    private

    def find_or_initialize(attrs)
      feature = attrs.fetch(:feature, "revenue_attribution")

      WaitlistSignup.find_or_initialize_by(feature: feature, email: attrs[:email]) do |signup|
        signup.source = attrs[:source]
      end
    end

    # A fresh token on every send, so an older email stops working. Somebody who
    # asked twice because the first did not arrive should not have two live
    # links, and the second is the one they are looking at.
    def issue(signup, attrs)
      token = SecureRandom.urlsafe_base64(32)

      signup.token_digest = WaitlistSignup.digest(token)
      signup.confirmation_sent_at = Time.current
      signup.source ||= attrs[:source]

      return Failure(validation: signup.errors.to_hash) unless signup.save

      # `deliver_later`, so a mail provider having a bad minute cannot hang the
      # request. It lands on within_5_seconds by the application-wide default,
      # which is the right tier: somebody is looking at the form waiting for it.
      WaitlistMailer.confirm(signup, token: token).deliver_later

      Success(:sent)
    end
  end
end
