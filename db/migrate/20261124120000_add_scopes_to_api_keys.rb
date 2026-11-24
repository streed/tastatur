# What an API key may do, so that the credential handed to an LLM agent cannot
# also assert "visitor X is user Y".
#
# Until now a key had exactly one purpose, POST /api/v1/identify, and so needed no
# notion of permission. The MCP endpoint reads analytics and revenue instead. A
# key that did both would make the secret pasted into an agent's configuration —
# the least controlled place a credential lives — equivalent to the one that writes
# identity, which is the write this whole table exists to keep unforgeable.
#
# EXISTING ROWS DEFAULT TO `write:identify`, which is precisely what they could do
# yesterday. Nothing gains a capability by this migration; a key must be created
# with `read:analytics` to read.
class AddScopesToApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :api_keys, :scopes, :string, array: true, null: false, default: ["write:identify"]
  end
end
