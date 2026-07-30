class User < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :confirmable, :lockable, :trackable,
         :recoverable, :rememberable, :validatable

  has_many :memberships, dependent: :destroy
  has_many :accounts, through: :memberships
  has_many :sites, through: :accounts

  scope :administrators, -> { where(admin: true) }
  scope :by_recency, -> { order(created_at: :desc) }

  # Case-insensitive substring match on email or name, for the admin console's
  # "find the person who just emailed us" box. Deliberately not a full-text
  # index: the table is small, support searches are rare, and an unused index on
  # a table Devise writes to on every sign-in is a cost with no reader.
  scope :matching, lambda { |query|
    next all if query.blank?

    term = "%#{sanitize_sql_like(query.to_s.strip)}%"
    where("email ILIKE :t OR name ILIKE :t", t: term)
  }

  # Devise's lockable sets locked_at; there is no predicate that reads well in a
  # view, and `access_locked?` also consults the unlock strategy.
  def locked? = locked_at.present?

  def confirmed? = confirmed_at.present?

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
