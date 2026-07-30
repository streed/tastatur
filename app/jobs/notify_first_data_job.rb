class NotifyFirstDataJob < ApplicationJob
  # Someone has just pasted the snippet and is watching the page to see whether it
  # worked. This email is the moment the product either proves itself or doesn't,
  # so it sits alongside the flush that makes their first event visible rather
  # than in a slower tier.
  queue_as :within_30_seconds

  # Enqueued by Ingest::RecordEvent the once, when a site's first event lands.
  #
  # `discard_on` rather than a retry for a deleted site: if the site or its owner
  # is gone by the time this runs, the notification is moot and retrying it
  # sixteen times only fills the dead set.
  discard_on ActiveRecord::RecordNotFound

  def perform(site_id)
    site = Site.find(site_id)
    recipient = site.account.owner

    # A self-hosted install created through the console can legitimately have no
    # owner membership. Nothing to do, and nothing worth raising about.
    return if recipient.nil?

    SiteMailer.first_data_received(site, recipient).deliver_now
  end
end
