require "rails_helper"

RSpec.describe Membership do
  # An account with no owner is unrecoverable through the interface: owner is the
  # role that can manage members, so there is nobody left who can appoint a
  # replacement. Both ways of losing the last one have to be closed, and for a
  # while only one of them was — the validation ran `on: :update`, so demoting the
  # last owner was refused and deleting them was not.
  describe "the last owner" do
    let(:account) { create(:account) }
    let!(:owner) { create(:membership, account: account, role: "owner") }

    it "cannot be demoted" do
      expect(owner.update(role: "member")).to be(false)
      expect(account.memberships.where(role: "owner").count).to eq(1)
    end

    it "cannot be deleted" do
      expect(owner.destroy).to be(false)
      expect(account.memberships.where(role: "owner").count).to eq(1)
    end

    it "explains why, so the interface can say something useful" do
      owner.destroy

      expect(owner.errors.full_messages.join).to include("must always have an owner")
    end

    it "raises on destroy! rather than silently succeeding" do
      expect { owner.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    end
  end

  describe "when another owner exists" do
    let(:account) { create(:account) }
    let!(:first) { create(:membership, account: account, role: "owner") }
    let!(:second) { create(:membership, account: account, role: "owner") }

    it "lets one of them be deleted" do
      expect(first.destroy).to be_truthy
      expect(account.memberships.where(role: "owner").count).to eq(1)
    end

    it "lets one of them be demoted" do
      expect(first.update(role: "admin")).to be(true)
    end
  end

  it "lets a non-owner be deleted" do
    account = create(:account)
    create(:membership, account: account, role: "owner")
    member = create(:membership, account: account, role: "member")

    expect(member.destroy).to be_truthy
  end

  # The guard must not make a single-owner account undeletable, which is what a
  # naive `before_destroy` does: the account's `dependent: :destroy` tries to
  # remove the owner and the guard refuses. `destroyed_by_association` is what
  # separates "remove this person" from "remove this whole account".
  it "does not prevent the account itself from being deleted" do
    account = create(:account)
    create(:membership, account: account, role: "owner")

    expect(account.destroy).to be_truthy
    expect(Membership.where(account_id: account.id).count).to be_zero
  end
end
