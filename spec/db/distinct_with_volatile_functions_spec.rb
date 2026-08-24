require "rails_helper"

# `SELECT DISTINCT` over a list containing a volatile function does nothing.
#
# This is not a style rule, it is a data-loss bug that has already happened here.
# 20260803160000 backfilled one campaign per distinct (site_id, utm_campaign)
# with:
#
#   SELECT DISTINCT site_id, utm_campaign, utm_campaign, gen_random_uuid(), ...
#
# DISTINCT applies to the WHOLE select list, and gen_random_uuid() returns a
# different value for every row, so no two rows are ever equal and nothing is
# de-duplicated. The migration then inserted one campaign per LINK and died on
# the unique index the first time two links shared a tag — which is the case the
# table exists for. It passed locally because the development database had no
# campaign links in it, so there was nothing to de-duplicate and nothing to
# collide, and it failed on the first deployment that had real data.
#
# The shape is easy to write again and reads as correct, so it is checked rather
# than remembered. NOW() and CURRENT_TIMESTAMP are deliberately NOT in the list:
# they are stable within a statement, so they do not break DISTINCT.
RSpec.describe "Migrations that de-duplicate" do
  VOLATILE = /\b(gen_random_uuid|uuid_generate_v4|random|clock_timestamp)\s*\(/i

  # Comments go first, or this flags the migration that explains the bug for
  # quoting the broken SQL it fixed — which it did, the first time it ran.
  def code(path)
    File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
  end

  # Each SELECT ... FROM, so a file with a correct subquery beside the DISTINCT
  # is not flagged for the volatile call in the outer query.
  def select_lists(sql)
    sql.scan(/SELECT\s+DISTINCT\b(.*?)\bFROM\b/im).flatten
  end

  it "never puts a volatile function in a SELECT DISTINCT list" do
    offenders = Dir[Rails.root.join("db/migrate/*.rb")].select do |path|
      select_lists(code(path)).any? { |list| list.match?(VOLATILE) }
    end

    expect(offenders.map { |p| File.basename(p) }).to be_empty,
      "These migrations DISTINCT over a volatile function, which silently de-duplicates " \
      "nothing: #{offenders.map { |p| File.basename(p) }.join(', ')}. Put the DISTINCT in a " \
      "subquery and generate the value in the outer SELECT — or leave the column out and let " \
      "its default fill it in."
  end

  # The same check for the edition, which writes into the same database (§20)
  # and has exactly the same reasons to backfill.
  it "holds for an edition's migrations too" do
    paths = Dir[Rails.root.join("editions/*/db/migrate/*.rb")]
    offenders = paths.select { |path| select_lists(code(path)).any? { |l| l.match?(VOLATILE) } }

    expect(offenders).to be_empty
  end
end
