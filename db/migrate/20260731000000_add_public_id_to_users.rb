# Users become routable, so they need a public identifier like everything else.
#
# Nothing else in this application is addressed by its primary key (see
# PubliclyIdentified and the AddPublicIds migration), and the admin console is
# the first screen that routes to a user at all. /admin/users/4 would leak the
# instance's user count to anyone who saw one URL — which, for a product whose
# customer count is competitive intelligence, is the same reason the other tables
# got UUIDs.
#
# The primary key stays bigint. Only the routed identifier changes.
class AddPublicIdToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :public_id, :uuid, default: -> { "gen_random_uuid()" }, null: false
    add_index :users, :public_id, unique: true
  end

  def down
    remove_column :users, :public_id
  end
end
