# Imports a newly connected Stripe account's history.
#
# `within_1_hour`, the nightly-bulk tier, and that is the right SLA despite this
# being triggered by somebody clicking a button. The tiers are named for what
# breaks if the queue backs up, not for how eager the person who started it feels.
# What breaks here is that a chart stays empty for a while longer — which is worth
# a real amount, but it is not worth putting minutes of Stripe pagination ahead of
# the buffered events that make every dashboard on the instance advance.
class BackfillStripeJob < ApplicationJob
  queue_as :within_1_hour

  discard_on ActiveRecord::RecordNotFound

  def perform(connection_id)
    connection = StripeConnection.find(connection_id)

    Revenue::BackfillStripe.call(connection: connection)
  end
end
