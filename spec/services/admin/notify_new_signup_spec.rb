require "rails_helper"

RSpec.describe Admin::NotifyNewSignup, type: :request do
  # `deliver_later`, so these assert on what is enqueued. A mail server having a
  # bad minute must not be able to fail a signup that has already succeeded.
  let(:new_user) { create(:user, email: "newcomer@example.com") }

  it "emails every instance administrator" do
    create(:user, admin: true, email: "a@example.com")
    create(:user, admin: true, email: "b@example.com")
    new_user

    expect { described_class.call(user_id: new_user.id) }
      .to have_enqueued_mail(AdminMailer, :new_signup).twice
  end

  it "reports how many were notified" do
    create(:user, admin: true)
    expect(described_class.call(user_id: new_user.id).value!).to eq(1)
  end

  it "names the new person in the subject" do
    create(:user, admin: true)

    perform_enqueued_jobs { described_class.call(user_id: new_user.id) }

    expect(ActionMailer::Base.deliveries.last.subject).to include("newcomer@example.com")
  end

  # Otherwise the first administrator on a fresh instance is emailed about
  # themselves, which reads as a bug in the first minute of using the product.
  it "does not email an administrator about their own signup" do
    admin = create(:user, admin: true)

    expect { described_class.call(user_id: admin.id) }
      .not_to have_enqueued_mail(AdminMailer, :new_signup)
  end

  it "sends nothing when there are no administrators" do
    new_user

    expect { described_class.call(user_id: new_user.id) }
      .not_to have_enqueued_mail(AdminMailer, :new_signup)
  end

  it "succeeds when there are no administrators, rather than failing" do
    expect(described_class.call(user_id: new_user.id).value!).to eq(:no_administrators)
  end

  # Deleted between enqueue and run. Raising would retry a job that can never
  # succeed.
  it "succeeds when the user is already gone" do
    create(:user, admin: true)
    expect(described_class.call(user_id: -1).value!).to eq(:user_gone)
  end

  describe "the signup hook" do
    before { create(:user, admin: true) }

    it "is enqueued when somebody registers" do
      expect do
        post user_registration_path, params: {
          user: { email: "signup@example.com", password: "password123", name: "New Person" }
        }
      end.to have_enqueued_job(NotifyAdminsOfSignupJob)
    end

    # Nobody is waiting on this one, and within_5_seconds is drained first — a
    # burst of signups there would queue in front of the confirmation emails those
    # same signups are waiting for.
    it "goes to the tier where nobody is waiting" do
      expect(NotifyAdminsOfSignupJob.new.queue_name).to eq("within_5_minutes")
    end
  end
end
