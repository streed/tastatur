class SiteMailer < ApplicationMailer
  # "Your site is live." Sent once, the moment a site's first event arrives.
  #
  # This is the only transactional email Tastatur sends that is not about
  # authentication, and it earns its place: the gap between pasting a snippet
  # and knowing whether it worked is where installations get abandoned. The
  # install screen polls, but people close tabs.
  def first_data_received(site, recipient)
    @site = site
    @recipient = recipient
    @dashboard_url = site_url(site)

    mail(
      to: recipient.email,
      subject: "#{site.domain} is sending data to Tastatur"
    )
  end
end
