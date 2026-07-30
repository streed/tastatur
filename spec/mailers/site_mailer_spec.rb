require "rails_helper"

RSpec.describe "First-data notification" do
  let(:owner) { create(:user, email: "owner@example.test") }
  let(:account) { create(:account, name: "Acme") }
  let(:site) { create(:site, account: account, domain: "measured.example.com") }

  before do
    create(:membership, account: account, user: owner, role: "owner")
    delete_all_events
    Ingest::WriteBuffer.clear!
    ActionMailer::Base.deliveries.clear
  end

  def send_pageview
    Ingest::RecordEvent.call(
      payload: { s: site.public_token, u: "https://measured.example.com/" },
      ip: "203.0.113.10",
      user_agent: "Mozilla/5.0 (Macintosh) Chrome/131.0.0.0"
    )
  end

  describe "the trigger" do
    it "enqueues the notification on the first event" do
      expect { send_pageview }
        .to have_enqueued_job(NotifyFirstDataJob).with(site.id)
    end

    # THE PROPERTY THAT MATTERS. Under real load several requests land in the
    # same millisecond and all of them would pass a Ruby `if nil?` check. Only
    # the conditional UPDATE can arbitrate, which is why the guard is
    # `update_all == 1` and not an in-memory test.
    it "enqueues exactly once no matter how many events arrive" do
      expect { 5.times { send_pageview } }
        .to have_enqueued_job(NotifyFirstDataJob).exactly(:once)
    end

    it "does not enqueue for a site that already had data" do
      site.update!(first_event_at: 1.day.ago)
      expect { send_pageview }.not_to have_enqueued_job(NotifyFirstDataJob)
    end

    it "still records the event itself" do
      send_pageview
      Ingest::WriteBuffer.flush!
      expect(Event.count).to eq(1)
      expect(site.reload.first_event_at).to be_present
    end
  end

  describe "the email" do
    before { site.update!(first_event_at: Time.current) }

    it "goes to the account owner" do
      NotifyFirstDataJob.perform_now(site.id)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq(["owner@example.test"])
      expect(mail.subject).to eq("measured.example.com is sending data to Tastatur")
    end

    it "links to the dashboard and the next steps" do
      NotifyFirstDataJob.perform_now(site.id)
      body = ActionMailer::Base.deliveries.last.body.to_s

      expect(body).to include(site.to_param)
      expect(body).to include("Open the dashboard")
      expect(body).to include("Set up a goal")
      expect(body).to include("Build a funnel")
    end

    it "is themed rather than a bare Rails email" do
      NotifyFirstDataJob.perform_now(site.id)
      body = ActionMailer::Base.deliveries.last.body.to_s

      expect(body).to include("#f2f1ec"), "paper background missing"
      expect(body).to include("#c1440e"), "accent missing"
      expect(body).to include("Tastatur")
    end

    it "comes from the configured address, not a placeholder" do
      NotifyFirstDataJob.perform_now(site.id)
      from = ActionMailer::Base.deliveries.last.from.first

      expect(from).to eq(ENV.fetch("MAIL_FROM", "no-reply@localhost"))
      expect(from).not_to include("example.com")
    end

    it "does nothing when the account has no owner" do
      # `delete_all`, not `destroy_all`: Membership now refuses to remove an
      # account's last owner, so `destroy_all` leaves the owner in place and this
      # example would silently stop testing anything. An ownerless account should
      # be unreachable through the application, and this asserts the mailer copes
      # if one turns up anyway — so it has to be manufactured past the callback.
      account.memberships.delete_all

      expect { NotifyFirstDataJob.perform_now(site.id) }
        .not_to change { ActionMailer::Base.deliveries.size }
    end

    it "discards rather than retrying when the site is gone" do
      id = site.id
      Sites::Delete.call(site: site)

      expect { NotifyFirstDataJob.perform_now(id) }.not_to raise_error
    end
  end
end

RSpec.describe "Devise mail theming" do
  let(:user) { create(:user) }

  # These emails are the only ones most users ever see. Devise's default parent
  # is ActionMailer::Base, which silently bypasses both our layout and our from
  # address, so this asserts the parent_mailer override is still in place.
  it "wraps Devise emails in the themed layout" do
    mail = Devise::Mailer.confirmation_instructions(user, "token")

    expect(Devise::Mailer.superclass).to eq(ApplicationMailer)
    expect(mail.body.to_s).to include("#f2f1ec")
    expect(mail.body.to_s).to include("#c1440e")
  end

  it "sends Devise email from the configured address" do
    mail = Devise::Mailer.confirmation_instructions(user, "token")

    expect(mail.from.first).to eq(ENV.fetch("MAIL_FROM", "no-reply@localhost"))
    expect(mail.from.first).not_to include("please-change-me")
  end

  it "uses subjects a person can act on" do
    expect(Devise::Mailer.confirmation_instructions(user, "t").subject)
      .to eq("Confirm your email address")
    expect(Devise::Mailer.reset_password_instructions(user, "t").subject)
      .to eq("Reset your password")
  end
end
