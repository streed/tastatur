class CreateDashboards < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboards do |t|
      t.references :site, null: false, foreign_key: true
      t.string :name, null: false

      # New table, so the public identifier ships with it — the backfill dance
      # in add_public_ids.rb is only for tables that predate the rule.
      t.uuid :public_id, default: -> { "gen_random_uuid()" }, null: false

      t.timestamps
    end
    add_index :dashboards, %i[site_id name], unique: true
    add_index :dashboards, :public_id, unique: true

    create_table :dashboard_widgets do |t|
      t.references :dashboard, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :kind, null: false

      # Optional; display falls back to a per-kind default (the metric's name,
      # the dimension's label, the funnel's name).
      t.string :title

      # Per-kind configuration as real, individually-checkable columns rather
      # than one config jsonb. Only the filter hash is jsonb, because its keys
      # are Analytics::Filters' vocabulary PLUS customer-chosen property names,
      # which no column set can enumerate.
      t.string  :metric                              # stat
      t.string  :dimension                           # breakdown
      t.integer :row_limit, null: false, default: 10 # breakdown; "limit" is a SQL keyword

      # NULLIFY, not cascade: deleting a funnel must not silently reshape a
      # dashboard someone curated. The widget stays and renders an explanatory
      # empty state pointing at the edit page. DashboardWidget gates the
      # presence validation on funnel_id CHANGING for the same reason.
      t.references :funnel, foreign_key: { on_delete: :nullify }

      t.jsonb :filters, null: false, default: {}

      t.timestamps
    end

    add_index :dashboard_widgets, %i[dashboard_id position], unique: true

    add_check_constraint :dashboard_widgets, "position > 0",
                         name: "dashboard_widgets_position_check"
    add_check_constraint :dashboard_widgets,
                         "kind IN ('stat', 'timeseries', 'breakdown', 'goals', 'funnel')",
                         name: "dashboard_widgets_kind_check"
    add_check_constraint :dashboard_widgets,
                         "metric IS NULL OR metric IN " \
                         "('visitors', 'pageviews', 'visits', 'bounce_rate', 'visit_duration')",
                         name: "dashboard_widgets_metric_check"
    add_check_constraint :dashboard_widgets, "row_limit BETWEEN 1 AND 50",
                         name: "dashboard_widgets_row_limit_check"

    # Deliberately NO `kind <> 'funnel' OR funnel_id IS NOT NULL` constraint: a
    # nullified funnel_id after funnel deletion is a legitimate state (the
    # "funnel was deleted" widget), and that constraint would make the FK's own
    # nullify action fail. And no constraint on `dimension`: the allowlist is
    # Analytics::Filters::DIMENSIONS, Analytics::Breakdown refuses unknown
    # dimensions independently, and pinning sixteen keys in a third place buys
    # a migration per new dimension for no additional safety.
  end
end
