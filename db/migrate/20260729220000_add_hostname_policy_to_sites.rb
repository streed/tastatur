# Hostname validation for ingest.
#
# The site token is public by construction: it sits in the HTML of every page it
# measures, so anyone can read it and POST events with it. That is true of every
# client-side analytics tool and cannot be fully prevented. What it CAN be is
# bounded, detectable and reversible.
#
# Before this, an event claiming any hostname at all was accepted and stored
# against the site. Verified: posting `u=https://attacker.example.net/spam-page`
# with a real token stored a row attributed to that site with that hostname.
#
# `extra_hostnames` covers the case the automatic rules do not: a site genuinely
# served on separate domains (example.com and example.de), which no subdomain
# rule can infer.
class AddHostnamePolicyToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :extra_hostnames, :string, array: true, null: false, default: []

    # Enforcement is on by default, because a site that silently accepts
    # poisoned data is worse than one that visibly rejects a hostname the owner
    # needs to add. The rejection counter makes the latter obvious.
    add_column :sites, :enforce_hostname, :boolean, null: false, default: true

    add_index :sites, :extra_hostnames, using: :gin
  end
end
