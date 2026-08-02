# Route templates the site owner declares so the path scrubber can collapse
# their dynamic segments EXACTLY, instead of guessing from a segment's shape.
#
# Ingest::PathScrubber already collapses things that *look* like identifiers
# (numbers, UUIDs, long high-entropy tokens). But a short, low-entropy record id
# is indistinguishable from a page name by shape alone: /sites/FB1WRC5D0PFFHKZ5
# is a 16-char token, /player/51 is a two-digit id, and a heuristic that caught
# every one of those would also collapse legitimate short page names. Declaring
# `/sites/:token` and `/player/:id` removes the guess: the segment in that
# position is named, so it is collapsed to `:token` / `:id` with no false
# positives and nothing leaked. Sites that declare nothing keep the heuristic.
#
# A string array, exactly like `extra_hostnames` next to it — a short list a
# site edits rarely, not a table.
class AddPathPatternsToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :path_patterns, :string, array: true, null: false, default: []
  end
end
