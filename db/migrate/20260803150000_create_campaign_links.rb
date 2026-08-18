# Dated ahead of this repository's previous newest migration and BEHIND the
# oldest an edition has contributed, which is not a free choice — see §20 and
# spec/db/migration_paths_spec.rb. That spec requires every edition migration to
# sort after every migration here, so a new one here dated today would fail it,
# and its stated remedy (re-date the edition's) means re-dating migrations
# already applied on the hosted deployment, which would re-run them. The
# timestamp encodes ordering rather than the calendar; the ordering it has to
# encode is "before anything private", because nothing private depends on this
# table and this table must not depend on anything private.
#
# 20260803150000 rather than the obvious next number, because two versions in
# this window (…130000, …140000) are already recorded in schema_migrations from
# work not in this checkout. Reusing one is not a conflict anybody sees: Rails
# keys applied migrations by version, so it is skipped silently and the table
# simply never exists. That happened once while this was being written, which is
# why the number looks arbitrary — check `SELECT version FROM schema_migrations`
# before picking one, not just `ls db/migrate`.
class CreateCampaignLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :campaign_links do |t|
      t.references :site, null: false, foreign_key: true

      # What the person who made it calls it. Not a UTM value — a campaign is
      # routinely one name across several links (email, twitter, the banner),
      # and this is the label that tells them apart in the list.
      t.string :name, null: false

      # The page the link lands on, stored as it was entered, including any
      # query string and fragment of its own. The tagged URL is built from this
      # at render time rather than stored alongside it: two columns that must
      # agree is one column that can be wrong, and the tagged form is a pure
      # function of the other six.
      t.string :destination_url, null: false

      t.string :utm_source, null: false
      t.string :utm_medium, null: false
      t.string :utm_campaign, null: false
      t.string :utm_term
      t.string :utm_content

      t.uuid :public_id, default: -> { "gen_random_uuid()" }, null: false

      t.timestamps
    end

    add_index :campaign_links, :public_id, unique: true
    add_index :campaign_links, %i[site_id name], unique: true

    # THE TUPLE IS THE JOIN KEY, so two links may not share one.
    #
    # A campaign link is measured by matching its five UTM values against the
    # events that carry them (Analytics::CampaignReport). Two links with
    # identical values are indistinguishable in the data, so the report would
    # have one row of visitors and two links claiming all of it — the same
    # figure shown twice, adding to double the traffic the site actually had.
    #
    # COALESCE rather than the bare columns: term and content are nullable, and
    # in a unique index NULL never equals NULL, so (google, cpc, launch, NULL,
    # NULL) could be saved any number of times — which is by a distance the
    # commonest shape of link this table will hold.
    add_index :campaign_links,
              "site_id, utm_source, utm_medium, utm_campaign, " \
              "COALESCE(utm_term, ''), COALESCE(utm_content, '')",
              unique: true, name: "index_campaign_links_on_site_and_utm"
  end
end
