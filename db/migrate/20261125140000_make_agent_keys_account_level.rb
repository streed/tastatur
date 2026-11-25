# An agent key belongs to an ACCOUNT, not a site.
#
# Per-site keys were the wrong grain for the people using them: an organisation
# with eight sites meant eight keys, eight pastes into the agent's configuration,
# and a new one every time a site was added. A member's access is already
# account-wide (a membership is of an account), so a key that mirrors it is
# neither broader than what its maker can do nor harder to reason about.
#
# So: `account_id` for keys that read, `site_id` for keys that write identity, and
# exactly one of them set. An identify key stays per-site on purpose: it belongs to
# one deployment's one site, and widening it would let a leaked server credential
# assert identities on every site in the account.
#
# EXISTING AGENT KEYS ARE CONVERTED, not dropped. They were made against a site; the
# account that site belongs to is where they now live, and the people holding them
# keep working.
class MakeAgentKeysAccountLevel < ActiveRecord::Migration[8.1]
  def up
    add_reference :api_keys, :account, null: true, foreign_key: { on_delete: :cascade }, index: true
    change_column_null :api_keys, :site_id, true

    # Converts anything that does not write identity. Run before the constraints.
    execute <<~SQL
      UPDATE api_keys
         SET account_id = sites.account_id, site_id = NULL
        FROM sites
       WHERE sites.id = api_keys.site_id
         AND NOT ('write:identify' = ANY (api_keys.scopes))
    SQL

    add_check_constraint :api_keys, "(site_id IS NULL) <> (account_id IS NULL)",
                         name: "api_keys_belongs_to_a_site_or_an_account"
    # An account key is bound to its maker (see AddUserToApiKeys). Without an owner
    # the membership check has nothing to check, which would make it immortal.
    add_check_constraint :api_keys, "account_id IS NULL OR user_id IS NOT NULL",
                         name: "api_keys_account_keys_have_an_owner"

    remove_index :api_keys, name: "index_api_keys_on_site_id_and_user_id_and_name"
    add_index :api_keys, %i[site_id name], unique: true, where: "site_id IS NOT NULL",
                                           name: "index_api_keys_on_site_id_and_name"
    add_index :api_keys, %i[account_id user_id name], unique: true, where: "account_id IS NOT NULL",
                                                      name: "index_api_keys_on_account_id_and_user_id_and_name"
  end

  def down
    remove_index :api_keys, name: "index_api_keys_on_account_id_and_user_id_and_name"
    remove_index :api_keys, name: "index_api_keys_on_site_id_and_name"
    remove_check_constraint :api_keys, name: "api_keys_account_keys_have_an_owner"
    remove_check_constraint :api_keys, name: "api_keys_belongs_to_a_site_or_an_account"

    # Pin each converted key back to the account's oldest site. Any site is a guess;
    # a key that reached them all has no single right answer. Keys of an account
    # with no sites at all are dropped, since a site key cannot exist without one.
    execute <<~SQL
      UPDATE api_keys
         SET site_id = (SELECT MIN(sites.id) FROM sites WHERE sites.account_id = api_keys.account_id)
       WHERE account_id IS NOT NULL
    SQL
    execute "DELETE FROM api_keys WHERE site_id IS NULL"

    add_index :api_keys, %i[site_id user_id name], unique: true, nulls_not_distinct: true,
                                                   name: "index_api_keys_on_site_id_and_user_id_and_name"
    change_column_null :api_keys, :site_id, false
    remove_reference :api_keys, :account, foreign_key: true, index: true
  end
end
