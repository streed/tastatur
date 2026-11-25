# Key names are unique per PERSON, not per site.
#
# Now that any member can make an agent key, "claude" is the obvious name for
# everybody's, and a site-wide uniqueness rule made the second teammate's attempt
# fail on a name they could not see (it is on somebody else's key, which the page
# deliberately hides from them).
#
# NULLS NOT DISTINCT keeps identify keys, which have no owner, unique per site
# exactly as before: without it Postgres treats every NULL as different and two
# unowned keys could share a name. Needs PostgreSQL 15+; this app runs 17.
class ScopeApiKeyNamesToTheirOwner < ActiveRecord::Migration[8.1]
  def change
    remove_index :api_keys, %i[site_id name], unique: true
    add_index :api_keys, %i[site_id user_id name], unique: true, nulls_not_distinct: true,
                                                   name: "index_api_keys_on_site_id_and_user_id_and_name"
  end
end
