class CreateFunnels < ActiveRecord::Migration[8.1]
  def change
    create_table :funnels do |t|
      t.references :site, null: false, foreign_key: true
      t.string :name, null: false

      # How long a visitor has to complete the whole funnel. Bounded on
      # purpose: without a persistent identifier we cannot follow someone
      # indefinitely, and an unbounded window would also make the query
      # unbounded. See docs/architecture/funnels.md.
      t.integer :window_seconds, null: false, default: 86_400

      # true  = steps must be reached in the declared order
      # false = steps may be reached in any order within the window
      t.boolean :strict_order, null: false, default: true

      t.timestamps
    end
    add_index :funnels, %i[site_id name], unique: true

    create_table :funnel_steps do |t|
      t.references :funnel, null: false, foreign_key: true
      t.integer :position, null: false
      t.string  :name, null: false

      # Same matcher vocabulary as Goal, so a step can reuse a goal's
      # semantics without depending on the goal record.
      t.string :kind, null: false
      t.string :match_value, null: false
      t.string :match_type, null: false, default: "exact"

      t.timestamps
    end

    add_index :funnel_steps, %i[funnel_id position], unique: true

    add_check_constraint :funnel_steps, "position > 0", name: "funnel_steps_position_check"
    add_check_constraint :funnel_steps, "kind IN ('pageview', 'event')", name: "funnel_steps_kind_check"
    add_check_constraint :funnel_steps,
                         "match_type IN ('exact', 'prefix', 'wildcard')",
                         name: "funnel_steps_match_type_check"
    add_check_constraint :funnels, "window_seconds BETWEEN 60 AND 2592000",
                         name: "funnels_window_seconds_check"
  end
end
