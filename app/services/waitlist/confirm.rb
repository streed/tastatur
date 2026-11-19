module Waitlist
  # Turns a claim about a mailbox into a member of the list.
  #
  # Idempotent on purpose. Mail clients prefetch links, people forward emails to
  # themselves, and somebody may simply click twice — none of which is an error
  # worth showing a stranger a failure page over. Confirming an already-confirmed
  # row succeeds and changes nothing, so `confirmed_at` keeps saying when the
  # permission was actually given rather than when the link was last opened.
  class Confirm < ApplicationService
    def initialize(token:)
      @token = token
    end

    def call
      signup = WaitlistSignup.find_by_token(@token)

      # One outcome for "no such token" and for "a token that was already used to
      # leave the list", because they are the same fact from outside: this link
      # does nothing. Distinguishing them would say whether an address was ever
      # on the list, to whoever holds the link.
      return Failure(:unknown_token) if signup.nil?

      signup.update!(confirmed_at: Time.current) unless signup.confirmed?

      Success(signup)
    end
  end
end
