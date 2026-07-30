class AccountsController < ApplicationController
  before_action :set_account

  def show
    authorize @account
    @memberships = policy_scope(Membership).includes(:user).order(:role, :created_at)
    # Rendered by the invite form. A form object rather than bare params so it
    # can use the shared form builder and report its own validation errors.
    @invitation = MemberInvitation.new
  end

  def edit
    authorize @account, :update?
  end

  def update
    authorize @account, :update?

    if @account.update(account_params)
      redirect_to account_path, notice: "Account updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_account
    @account = current_account
    raise ActiveRecord::RecordNotFound if @account.nil?
  end

  def account_params
    # data_retention_days is a compliance control, so it is editable here
    # rather than buried in a per-site setting.
    params.expect(account: %i[name data_retention_days])
  end
end
