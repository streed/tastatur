module Waitlist
  # Deletes addresses that were entered and never confirmed.
  #
  # An unconfirmed row is not a list member — it is an assertion by an
  # unauthenticated stranger that some mailbox wants to hear from us, and quite
  # possibly an assertion about somebody else's mailbox. Holding those
  # indefinitely would mean the database slowly fills with addresses nobody
  # consented to give us, which is precisely the thing this product exists to not
  # do. The confirmation email says they are deleted within a week, so this is
  # the code that keeps a written promise.
  #
  # `delete_all`, not `destroy_all`: there are no callbacks and no dependents,
  # and the point is to remove rows rather than to instantiate them.
  class PurgeUnconfirmed < ApplicationService
    def call
      deleted = WaitlistSignup.pending
                              .where(created_at: ..WaitlistSignup::PENDING_LIFETIME.ago)
                              .delete_all

      Success(deleted)
    end
  end
end
