require "rails_helper"

# Two repositories can contribute migrations to one database — this one, and any
# edition (config/application.rb). That is a genuinely useful arrangement and it
# has exactly one sharp edge, which this file blunts.
#
# There is no schema file to reconcile against (§8), so migrations ARE the
# schema, in every environment, forever. A version number colliding between the
# two repositories is therefore not a merge conflict somebody resolves; it is one
# migration that silently never runs on a fresh install, because
# `ActiveRecord::Migrator` keys applied migrations by version and a version it
# has already seen is a version it skips.
#
# Rails does raise `DuplicateMigrationVersionError` on `db:migrate` — but only on
# the deployment that has both repositories checked out, only when somebody runs
# it, and by then the two migrations are already committed to two histories that
# have to be rewritten together. Catching it in the suite costs one file.
RSpec.describe "Migration paths" do
  # Every directory Rails will actually run migrations from, which is this
  # repository's plus one per edition. Asked of the application rather than
  # globbed, so an edition that changes how it registers its path is still
  # covered.
  def migration_paths
    Rails.application.config.paths["db/migrate"].expanded
  end

  def migration_files
    migration_paths.flat_map { |dir| Dir[File.join(dir, "*.rb")] }
  end

  def version_of(file)
    File.basename(file)[/\A(\d+)_/, 1]
  end

  it "runs at least this repository's own migrations" do
    # The control. Without it, a typo in `migration_paths` would empty every
    # assertion below and the file would pass by finding nothing.
    expect(migration_files.size).to be >= 25
  end

  it "gives every migration a version no other migration claims" do
    by_version = migration_files.group_by { |f| version_of(f) }
    collisions = by_version.select { |_, files| files.size > 1 }

    expect(collisions).to be_empty,
                          "Two migrations share a version number, so one of them will never run on a " \
                          "fresh install: " +
                          collisions.map { |v, files| "#{v} — #{files.map { |f| f.sub("#{Rails.root}/", "") }.join(" and ")}" }
                                    .join("; ")
  end

  it "names every migration file the way Rails parses it" do
    malformed = migration_files.reject { |f| File.basename(f).match?(/\A\d{14}_[a-z0-9_]+\.rb\z/) }

    expect(malformed).to be_empty,
                         "Migrations Rails will not recognise: #{malformed.join(", ")}"
  end

  # THE ONE-DIRECTIONAL RULE, in the only form a spec can check it.
  #
  # An edition's migrations may depend on this repository's — a private feature
  # can perfectly well reference `sites` — but never the reverse, because this
  # repository has to migrate to a working database with no edition present at
  # all. A migration here that ran second to an edition's would break the
  # community edition and nothing in this suite would notice, since the hosted
  # deployment has both.
  #
  # What that reduces to mechanically: every edition migration must sort AFTER
  # every migration in this repository at the time it was written. Since both are
  # timestamps and this repository came first, the check is that no edition
  # migration is older than the newest one here — a new edition migration
  # back-dated to slot in among the community ones is precisely the mistake.
  it "keeps edition migrations after this repository's, never interleaved among them" do
    own_dir = Rails.root.join("db/migrate").to_s
    own, edition = migration_files.partition { |f| File.dirname(f) == own_dir }

    next if edition.empty?

    newest_own = own.map { |f| version_of(f) }.max
    too_early = edition.select { |f| version_of(f) < newest_own }

    expect(too_early).to be_empty,
                         "These edition migrations are dated before this repository's newest migration " \
                         "(#{newest_own}), so the order they run in depends on which repository is " \
                         "checked out: #{too_early.map { |f| File.basename(f) }.join(", ")}. " \
                         "Re-date them to now."
  end
end
