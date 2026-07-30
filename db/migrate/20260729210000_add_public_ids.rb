# Public identifiers become UUIDs.
#
# Sequential integers in URLs leak information even when the endpoint is properly
# authorized: /sites/4/goals/17 tells anyone who sees it roughly how many sites
# and goals exist across the whole instance, and it makes enumeration the obvious
# first thing to try. For a multi-tenant analytics product that is free
# competitive intelligence about our own customer count.
#
# The primary keys stay `bigint`. That is deliberate: bigint keys are narrower,
# index better, and keep foreign keys cheap, and none of that is visible outside
# the database. Only the *routed* identifier changes, via `to_param` on each
# model.
#
# PostgreSQL 13+ has gen_random_uuid() built in, so no pgcrypto extension is
# needed.
class AddPublicIds < ActiveRecord::Migration[8.1]
  TABLES = %i[goals funnels shared_links memberships accounts].freeze

  def up
    TABLES.each do |table|
      add_column table, :public_id, :uuid, default: -> { "gen_random_uuid()" }, null: false
      add_index table, :public_id, unique: true
    end
  end

  def down
    TABLES.each { |table| remove_column table, :public_id }
  end
end
