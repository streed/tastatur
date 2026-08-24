# A campaign is a NAME and a tag; the links under it are how it was distributed.
#
# WHY THIS TABLE EXISTS. campaign_links already held a `name` — "August
# newsletter — main button" — and its own comment said out loud that "a campaign
# is routinely one name across several links (email, twitter, the banner)". It
# just had nowhere to say so. The result was one row per channel with no way to
# ask what the campaign as a whole did, and the only figure the product offered
# for that was the dashboard's Campaigns panel, three screens away and grouped by
# a column rather than by anything the customer had built.
#
# THE TAG IS THE GROUPING, and that is what makes the campaign-level figure real
# rather than cosmetic. Every link under a campaign carries the campaign's own
# `utm_campaign` value, so "what did August launch do" is one GROUP BY over the
# events that carry that value — an exact COUNT(DISTINCT), computed once, over
# the same rows. The alternative considered and rejected was a pure folder with
# each link keeping its own tag: there is then no shared value to group by, so
# the only campaign total available is the SUM of its links' visitor counts,
# which double-counts everybody who clicked two of them. §8 forbids exactly that
# addition for the same reason, one grain down.
#
# utm_campaign STAYS ON THE LINK, denormalised, rather than being read through
# the association. It is half the join key that matches a link to its events
# (Analytics::CampaignReport), and that key is enforced by the unique index
# added in 20260803150000 — an index cannot span a join. The model keeps the
# copy in step; the column is not a second opinion.
#
# On the timestamp: see the header of 20260803150000. The window between this
# repository's newest and the oldest an edition contributes is the only place a
# migration here may sit, ...140000 and ...130000 are already burned in local
# schema_migrations, and ...150000 is the campaign_links table itself. This is
# the next free number in that window, not today's date.
class CreateCampaigns < ActiveRecord::Migration[8.1]
  def up
    create_table :campaigns do |t|
      t.references :site, null: false, foreign_key: true

      # What the customer calls it. This is the "What is this for?" heading on
      # the screen, and it never leaves the product — no visitor ever sees it.
      t.string :name, null: false

      # What every link under it tags with, and therefore what the events carry.
      # Lower-cased on write by the model, like every other UTM value here: the
      # match is exact and case-sensitive, and `Newsletter` beside `newsletter`
      # is the split campaign this whole feature exists to make visible.
      t.string :utm_campaign, null: false

      t.uuid :public_id, default: -> { "gen_random_uuid()" }, null: false

      t.timestamps
    end

    add_index :campaigns, :public_id, unique: true
    add_index :campaigns, %i[site_id name], unique: true

    # ONE CAMPAIGN PER TAG PER SITE, which is the invariant the figure above
    # depends on. Two campaigns sharing a tag would each group the same events
    # and each claim all of them — the doubled-traffic failure the link-level
    # tuple index was added to prevent, one level up.
    add_index :campaigns, %i[site_id utm_campaign], unique: true

    add_reference :campaign_links, :campaign, foreign_key: true

    # Every link that already exists belongs somewhere, and the tag it already
    # carries says where: links sharing a tag were one campaign all along and
    # simply had no row to say so. Named after the tag, because it is the only
    # thing on the row that describes the campaign rather than the channel — the
    # link's own name is "August newsletter — main button", which names one of
    # them and would be a poor heading for the other four.
    execute <<~SQL
      INSERT INTO campaigns (site_id, name, utm_campaign, public_id, created_at, updated_at)
      SELECT DISTINCT site_id, utm_campaign, utm_campaign, gen_random_uuid(), NOW(), NOW()
      FROM campaign_links
    SQL

    execute <<~SQL
      UPDATE campaign_links AS l
      SET campaign_id = c.id
      FROM campaigns AS c
      WHERE c.site_id = l.site_id AND c.utm_campaign = l.utm_campaign
    SQL

    # Only after the backfill, or the column could never have been added to a
    # table with rows in it.
    change_column_null :campaign_links, :campaign_id, false

    # A LINK'S NAME IS NOW A CHANNEL LABEL, so it is unique within its campaign
    # rather than within the site. "Discord" is exactly the right name for a
    # link under August launch and again under the Christmas one, and a
    # site-wide constraint would refuse the second with a message about a link
    # the person may not even remember building.
    remove_index :campaign_links, column: %i[site_id name]
    add_index :campaign_links, %i[campaign_id name], unique: true
  end

  def down
    remove_index :campaign_links, column: %i[campaign_id name]
    add_index :campaign_links, %i[site_id name], unique: true

    remove_reference :campaign_links, :campaign, foreign_key: true
    drop_table :campaigns
  end
end
