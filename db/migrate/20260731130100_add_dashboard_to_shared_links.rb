class AddDashboardToSharedLinks < ActiveRecord::Migration[8.1]
  def change
    # NULL means "the default dashboard", which is every link that exists
    # today, so there is nothing to backfill.
    #
    # When the dashboard is deleted the link must be DESTROYED, never pointed
    # back at the default dashboard: a link was scoped to exactly what its
    # widgets showed, and falling back would silently WIDEN what an
    # already-distributed URL exposes. Dashboard's `has_many :shared_links,
    # dependent: :destroy` does that work; the plain FK here is the backstop
    # that turns any callback-skipping delete into a loud error rather than a
    # widened link.
    add_reference :shared_links, :dashboard, foreign_key: true
  end
end
