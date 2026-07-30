class CreateSites < ActiveRecord::Migration[8.1]
  def change
    create_table :sites do |t|
      t.references :account, null: false, foreign_key: true

      # The hostname being measured, normalised to lowercase and stripped of
      # any scheme, port, "www." and trailing slash before it lands here.
      t.string :domain, null: false

      # What goes in <script data-site="...">. Deliberately NOT the primary
      # key: it is published in the HTML of every page on the customer's site,
      # so it must not leak row counts or be guessable into another tenant's
      # data. 16 chars of a 32-symbol alphabet ≈ 1.2e24 possibilities.
      t.string :public_token, null: false, limit: 16

      # Reporting timezone. All dashboard bucketing is done in this zone;
      # storage is always UTC.
      t.string :timezone, null: false, default: "Etc/UTC"

      # Suppress any breakdown row seen by fewer than this many distinct
      # visitors. A per-site knob because the right threshold depends on
      # traffic volume — see Site#k_anonymity_threshold.
      t.integer :k_anonymity_threshold, null: false, default: 25

      # Set the first time an event arrives. Drives the onboarding
      # "waiting for your first pageview" screen.
      t.datetime :first_event_at

      t.timestamps
    end

    add_index :sites, :public_token, unique: true
    add_index :sites, %i[account_id domain], unique: true

    add_check_constraint :sites,
                         "k_anonymity_threshold >= 0",
                         name: "sites_k_anonymity_threshold_check"
  end
end
