module Ingest
  # The two opaque handles that stand in for a person, and nothing else.
  #
  # Neither can be reversed, and both stop being meaningful once the salt that
  # produced them is destroyed. There is deliberately no field here for an IP
  # address, a user-agent string, or anything else the hash was derived from:
  # those exist as local variables inside Identifier#call and are never carried
  # any further into the system.
  class Identity < Dry::Struct
    # 16 raw bytes, ready to go straight into the `bytea` columns.
    attribute :visitor_hash, Types::Strict::String
    attribute :session_hash, Types::Strict::String

    # True when this event opened a new session, which makes it the entry
    # pageview for bounce-rate and entry-page reporting.
    attribute :new_session, Types::Strict::Bool

    def entry?
      new_session
    end

    def visitor_hex = visitor_hash.unpack1("H*")
    def session_hex = session_hash.unpack1("H*")
  end
end
