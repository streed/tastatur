class RotateVisitorSaltJob < ApplicationJob
  # Minutes, not seconds. Nobody is waiting on this, but a salt that outlives its
  # day weakens the unlinkability claim for as long as the delay lasts, which puts
  # it above the nightly sweeps and below anything interactive.
  queue_as :within_5_minutes

  # Runs daily. Rotating the salt is what makes yesterday's visitor hashes
  # permanently unlinkable to today's — if this job stops running, the product
  # quietly stops being anonymous, so its failure is worth alerting on rather
  # than retrying quietly.
  def perform
    Ingest::SaltStore.rotate!
  end
end
