class EnforceDataRetentionJob < ApplicationJob
  # An hour. This is a nightly bulk delete across compressed chunks, scheduled at
  # 03:23 precisely because nothing is waiting for it. If it slips an hour, the
  # data it would have deleted is a few hours past its window rather than
  # unlawfully retained.
  queue_as :within_1_hour

  def perform
    Privacy::EnforceDataRetention.call
  end
end
