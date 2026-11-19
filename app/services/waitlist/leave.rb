module Waitlist
  # Takes an address off the list by DELETING it.
  #
  # The industry default is a suppression list: keep the row, set a flag, never
  # mail it again. That is a defensible engineering answer and the wrong one
  # here. It means the answer to "please stop holding my email address" is a
  # database row holding their email address, kept specifically because they
  # asked us not to have it. A product whose entire argument is that it stores
  # less than the alternatives does not get to make that trade for a marketing
  # list.
  #
  # What we give up is the ability to refuse a re-subscription. That is fine:
  # rejoining requires a fresh confirmation click from the mailbox itself, so the
  # only person who can put an address back is the person who reads it.
  class Leave < ApplicationService
    def initialize(token:)
      @token = token
    end

    def call
      signup = WaitlistSignup.find_by_token(@token)
      return Failure(:unknown_token) if signup.nil?

      signup.destroy!

      Success(:removed)
    end
  end
end
