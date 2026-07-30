class CreateGoals < ActiveRecord::Migration[8.1]
  def change
    create_table :goals do |t|
      t.references :site, null: false, foreign_key: true
      t.string :name, null: false

      # "pageview" matches against the request path; "event" matches against a
      # custom event name sent via tastatur('event', ...).
      t.string :kind, null: false

      # For kind=pageview this is a path pattern ("/pricing", "/blog/**").
      # For kind=event this is the event name ("Signup").
      t.string :match_value, null: false

      # exact | prefix | wildcard. Wildcard patterns are compiled to a SQL
      # LIKE at query time; see Analytics::PathPattern.
      t.string :match_type, null: false, default: "exact"

      # Optional monetary value. Goals that carry revenue read it off the
      # event payload; goals with a fixed value use default_value_cents.
      t.integer :default_value_cents
      t.string  :currency, limit: 3

      t.timestamps
    end

    add_index :goals, %i[site_id name], unique: true
    add_index :goals, %i[site_id kind]

    add_check_constraint :goals, "kind IN ('pageview', 'event')", name: "goals_kind_check"
    add_check_constraint :goals,
                         "match_type IN ('exact', 'prefix', 'wildcard')",
                         name: "goals_match_type_check"
  end
end
