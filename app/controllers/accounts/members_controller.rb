module Accounts
  class MembersController < ApplicationController
    before_action :set_account

    def index
      @memberships = policy_scope(Membership).includes(:user).order(:role)
    end

    def create
      authorize Membership.new(account: @account), :create?

      @invitation = MemberInvitation.new(invitation_params)
      return render_account_with_errors unless @invitation.valid?

      case Accounts::InviteMember.call(
        account: @account, email: @invitation.normalized_email, role: @invitation.role,
        # Named in the invitation email. "Someone added you to an account" is the
        # shape of a phishing message; a name the recipient recognises is not.
        invited_by: current_user
      )
      in Success(membership)
        redirect_to account_path, notice: "#{membership.user.email} was added to #{@account.name}."
      in Failure(:already_a_member)
        @invitation.errors.add(:email, "is already a member of this account")
        render_account_with_errors
      in Failure(reason)
        @invitation.errors.add(:base, reason.to_s.humanize)
        render_account_with_errors
      end
    end

    def update
      membership = policy_scope(Membership).find_by_public_id!(params[:id])
      authorize membership

      if membership.update(role: params[:role])
        redirect_to account_path, notice: "Role updated."
      else
        redirect_to account_path, alert: membership.errors.full_messages.to_sentence
      end
    end

    def destroy
      membership = policy_scope(Membership).find_by_public_id!(params[:id])
      authorize membership

      # `destroy`, not `destroy!`. Membership refuses to remove an account's last
      # owner, and with the bang that refusal arrived as a RecordNotDestroyed and
      # a 500 — an explanation the person needs, delivered as a crash.
      if membership.destroy
        redirect_to account_path, notice: "Member removed."
      else
        redirect_to account_path, alert: membership.errors.full_messages.to_sentence
      end
    end

    private

    def set_account
      @account = current_account
      raise ActiveRecord::RecordNotFound if @account.nil?
    end

    def invitation_params
      params.expect(invitation: %i[email role])
    end

    # Re-renders the account page with the invite form's errors intact, rather
    # than bouncing to a flash message that loses what was typed.
    def render_account_with_errors
      @memberships = policy_scope(Membership).includes(:user).order(:role, :created_at)
      # The account page renders the two-factor card too, so re-rendering it from
      # here has to supply everything that page reads. A missing ivar would be a
      # NoMethodError on nil reachable only by mistyping an email address.
      @trusted_devices = current_user.visible_trusted_devices
      render "accounts/show", status: :unprocessable_entity
    end
  end
end
