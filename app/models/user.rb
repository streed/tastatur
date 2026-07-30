class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :confirmable, :lockable, :trackable,
         :recoverable, :rememberable, :validatable

  has_many :memberships, dependent: :destroy
  has_many :accounts, through: :memberships
  has_many :sites, through: :accounts

  # Every user gets a personal account on signup, so `default_account` is only
  # nil for a user whose accounts have all been deleted.
  def default_account
    accounts.order(:created_at).first
  end

  def membership_for(account)
    return nil if account.nil?

    memberships.find_by(account_id: account.id)
  end

  def member_of?(account)
    membership_for(account).present?
  end

  # Used by the Pundit policies. `admin` on the User record is the
  # instance-wide superuser flag from the starter template and is deliberately
  # NOT the same thing as being an admin of an account.
  def role_in(account)
    membership_for(account)&.role
  end
end
