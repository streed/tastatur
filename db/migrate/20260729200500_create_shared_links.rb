class CreateSharedLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :shared_links do |t|
      t.references :site, null: false, foreign_key: true
      t.string :name, null: false

      # Unguessable public slug. Same reasoning as Site#public_token: this is
      # the ONLY thing standing between an anonymous visitor and a tenant's
      # stats, so it is generated from SecureRandom and never derived from the
      # site id, domain, or name.
      t.string :slug, null: false, limit: 24

      # Optional bcrypt digest. Nil means "anyone with the link can view".
      t.string :password_digest

      t.datetime :expires_at
      t.datetime :last_viewed_at
      t.integer  :view_count, null: false, default: 0

      t.timestamps
    end

    add_index :shared_links, :slug, unique: true
    add_index :shared_links, %i[site_id name], unique: true
  end
end
