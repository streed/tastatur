# A widget is addressed directly now that it is configured on the dashboard
# itself rather than through one big nested form, so it needs the routed
# identifier §10 requires. `dashboard_widgets` predates that need by one
# migration, so unlike CreateDashboards this has to backfill before it can add
# the NOT NULL — the same dance as add_public_ids.rb.
class AddPublicIdToDashboardWidgets < ActiveRecord::Migration[8.1]
  def up
    add_column :dashboard_widgets, :public_id, :uuid, default: -> { "gen_random_uuid()" }
    execute "UPDATE dashboard_widgets SET public_id = gen_random_uuid() WHERE public_id IS NULL"
    change_column_null :dashboard_widgets, :public_id, false
    add_index :dashboard_widgets, :public_id, unique: true
  end

  def down
    remove_column :dashboard_widgets, :public_id
  end
end
