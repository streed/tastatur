class PurgeUnconfirmedWaitlistSignupsJob < ApplicationJob
  # Nightly bulk work, and nothing is waiting for it: an address that has sat
  # unconfirmed for a week can sit unconfirmed for another hour. It is on the
  # schedule at all because the email tells the recipient this happens, which
  # makes it a written promise rather than housekeeping.
  queue_as :within_1_hour

  def perform
    Waitlist::PurgeUnconfirmed.call
  end
end
