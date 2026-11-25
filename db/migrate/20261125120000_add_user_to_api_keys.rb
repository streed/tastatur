# Who made an agent key, so that it dies with their access.
#
# An analytics key is tied to a SITE, not to a person, and until now only an admin
# could mint one, so the question of whose it was never came up. Letting any
# member of an organisation connect an AI agent raises it at once: a viewer who
# mints a key and is then removed from the organisation would otherwise keep
# reading the site's analytics for as long as the key lived, which is the exact
# thing removing them was meant to end.
#
# So a key with an owner is honoured only while the owner is still a member of
# the site's account (ApiKey.authenticate checks, on every request, and answers
# with the same 401 as any other bad key). Keys with NO owner — every identify
# key, which belongs to a deployment and must survive its creator leaving — are
# exactly as before.
#
# CASCADE, NOT NULLIFY. A nulled owner reads as "no owner", which is the
# unrestricted case; deleting a user must remove the key, not set it free.
class AddUserToApiKeys < ActiveRecord::Migration[8.1]
  def change
    add_reference :api_keys, :user, null: true, foreign_key: { on_delete: :cascade }, index: true
  end
end
