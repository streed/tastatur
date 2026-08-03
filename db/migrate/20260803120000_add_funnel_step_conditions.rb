class AddFunnelStepConditions < ActiveRecord::Migration[8.1]
  # A funnel step was one matcher. It is now a SET of matchers, any one of which
  # satisfies the step: "Signed up" is the /welcome pageview OR the Signup
  # event, and "Viewed a product" is /products/** OR /p/**. Without this a
  # funnel that branches has to be split into one funnel per branch, and no
  # combination of those answers the question that was asked — the visitors are
  # counted once per funnel with no way to add them up, because a visitor who
  # took both branches is in both.
  #
  # The three matcher columns MOVE off funnel_steps rather than being kept
  # alongside the new table. Leaving them would give a step two places to say
  # what it matches, only one of which the report reads, and the other would
  # drift into a lie that shows up as a funnel reporting on a matcher nobody
  # can see in the form.
  def up
    create_table :funnel_step_conditions do |t|
      t.references :funnel_step, null: false, foreign_key: true
      t.integer :position, null: false

      # Same matcher vocabulary as Goal and as the funnel_steps columns this
      # replaces. Kind is per CONDITION, not per step, which is the whole point:
      # one step may be satisfied by a pageview or by a custom event.
      t.string :kind, null: false
      t.string :match_value, null: false
      t.string :match_type, null: false, default: "exact"

      t.timestamps
    end

    add_index :funnel_step_conditions, %i[funnel_step_id position], unique: true

    add_check_constraint :funnel_step_conditions, "position > 0",
                         name: "funnel_step_conditions_position_check"
    add_check_constraint :funnel_step_conditions, "kind IN ('pageview', 'event')",
                         name: "funnel_step_conditions_kind_check"
    add_check_constraint :funnel_step_conditions,
                         "match_type IN ('exact', 'prefix', 'wildcard')",
                         name: "funnel_step_conditions_match_type_check"

    # Every existing step becomes a one-condition step, which is exactly what it
    # already was. Done before the columns are dropped, obviously, and in the
    # same migration so no deploy sits between a step losing its matcher and
    # gaining one.
    execute(<<~SQL.squish)
      INSERT INTO funnel_step_conditions
        (funnel_step_id, position, kind, match_value, match_type, created_at, updated_at)
      SELECT id, 1, kind, match_value, match_type, NOW(), NOW()
      FROM funnel_steps
    SQL

    remove_check_constraint :funnel_steps, name: "funnel_steps_kind_check"
    remove_check_constraint :funnel_steps, name: "funnel_steps_match_type_check"
    remove_column :funnel_steps, :kind
    remove_column :funnel_steps, :match_value
    remove_column :funnel_steps, :match_type
  end

  # Reversible, but LOSSY by construction: a step with alternatives cannot be
  # expressed in one set of columns, so rolling back keeps the first condition
  # and discards the rest. That is the honest answer — the alternative is a
  # rollback that silently reports a different funnel.
  def down
    add_column :funnel_steps, :kind, :string
    add_column :funnel_steps, :match_value, :string
    add_column :funnel_steps, :match_type, :string, default: "exact"

    execute(<<~SQL.squish)
      UPDATE funnel_steps s
      SET kind = c.kind, match_value = c.match_value, match_type = c.match_type
      FROM funnel_step_conditions c
      WHERE c.funnel_step_id = s.id AND c.position = 1
    SQL

    # A step whose conditions were all destroyed leaves nothing to restore, and
    # NOT NULL has to hold before it is declared.
    execute(<<~SQL.squish)
      UPDATE funnel_steps
      SET kind = 'pageview', match_value = '/', match_type = 'exact'
      WHERE kind IS NULL
    SQL

    change_column_null :funnel_steps, :kind, false
    change_column_null :funnel_steps, :match_value, false
    change_column_null :funnel_steps, :match_type, false

    add_check_constraint :funnel_steps, "kind IN ('pageview', 'event')",
                         name: "funnel_steps_kind_check"
    add_check_constraint :funnel_steps, "match_type IN ('exact', 'prefix', 'wildcard')",
                         name: "funnel_steps_match_type_check"

    drop_table :funnel_step_conditions
  end
end
