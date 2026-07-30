class FlushEventBufferJob < ApplicationJob
  # Half a minute, because that is how stale the dashboard is allowed to look.
  # Events sit in Redis until this runs, so a backlog is invisible to the person
  # sending them — ingest keeps answering 202 — and visible to the site owner as
  # numbers that have stopped moving.
  #
  # Below `within_5_seconds` deliberately, even though this is the hottest job in
  # the system. Sidekiq drains the list strictly, so putting frequent bulk writes
  # in the top tier would let them sit in front of a confirmation email that
  # somebody is waiting on.
  queue_as :within_30_seconds

  # Two flushes running at once would each drain part of the buffer, which is
  # harmless — LPOP is atomic and no event is popped twice. So there is no lock
  # here on purpose.
  def perform
    written = Ingest::WriteBuffer.flush!
    Rails.logger.debug { "[tastatur] flushed #{written} events" } if written.positive?
    written
  end
end
