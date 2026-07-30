class CreateAccountsAndMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string  :name, null: false
      t.string  :slug, null: false

      # Billing. Stripe is wired but dormant until a plan is assigned, so a
      # self-hosted install never has to think about it.
      t.string  :stripe_customer_id
      t.string  :stripe_subscription_id
      t.string  :plan, null: false, default: "free"
      t.integer :monthly_event_limit, null: false, default: 10_000
      t.datetime :trial_ends_at

      # Retention is a per-tenant compliance knob, not a global constant: a
      # controller may be required to hold analytics for a shorter period than
      # our default. Enforced by a nightly job against the raw hypertable.
      t.integer :data_retention_days, null: false, default: 400

      t.timestamps
    end
    add_index :accounts, :slug, unique: true
    add_index :accounts, :stripe_customer_id, unique: true, where: "stripe_customer_id IS NOT NULL"

    create_table :memberships do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user,    null: false, foreign_key: true
      t.string     :role,    null: false, default: "member"
      t.timestamps
    end
    add_index :memberships, %i[account_id user_id], unique: true

    # Roles are a closed set; a typo should fail at write time rather than
    # silently granting nothing (or everything) in a Pundit policy.
    add_check_constraint :memberships,
                         "role IN ('owner', 'admin', 'member', 'viewer')",
                         name: "memberships_role_check"
  end
end
