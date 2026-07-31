# The currency every revenue figure for this site is reported in.
#
# It is a property of the SITE rather than of the connected Stripe account,
# because Stripe accounts are routinely multi-currency — a single account can
# charge in USD, EUR and GBP — and a report has to pick one to add up in. Asking
# the site owner is the only way to get that right; inferring it from the first
# invoice we happen to see gets it right most of the time, which is the worst
# kind of wrong for a money column.
#
# Defaulted to USD rather than left NULL so that every existing site has a valid
# answer the moment Stripe is connected, and no report has a nil branch.
class AddBaseCurrencyToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :base_currency, :string, null: false, default: "USD", limit: 3

    add_check_constraint :sites, "base_currency ~ '^[A-Z]{3}$'",
                         name: "sites_base_currency_check"
  end
end
