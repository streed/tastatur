module Ingest
  # Decides whether an event continues an existing visit or starts a new one.
  #
  # A session is "the same visitor, with no gap longer than the timeout". That
  # is a sliding window, which is exactly what a Redis key with a TTL is: the
  # key holds the session id, every event pushes its expiry back, and if the
  # visitor goes quiet for longer than the timeout the key evaporates and the
  # next event opens a fresh session.
  #
  # Redis rather than a database table because this runs on every single
  # ingest request. A SELECT-then-UPDATE against PostgreSQL per pageview would
  # make the write path several times more expensive and would contend on the
  # same rows under load, whereas this is one round trip against an in-memory
  # key that expires on its own.
  #
  # The state here is intentionally disposable. If Redis is lost, in-flight
  # sessions restart — visits get split and the visit count ticks up slightly
  # for one timeout window. That is an acceptable failure mode for analytics
  # and a much better one than persisting visitor state to disk.
  class SessionWindow
    SESSION_BYTES = 16

    # Named here rather than inlined, because Ingest::SaltStore#destroy_all! has to
    # sweep these too: the key embeds a visitor hash, so leaving them behind after
    # "destroy all salts" would leave the linkable state the operator was trying to
    # remove.
    KEY_PREFIX = "tastatur:session:".freeze

    def initialize(site_id:, visitor_hash:)
      @site_id = site_id
      @visitor_hash = visitor_hash
    end

    # Returns [session_hash, new_session?].
    #
    # If no live session exists, the block is given a chance to supply one
    # carried over from the previous salt (see Identifier) before we conclude
    # this is a new visit.
    def resolve
      existing = touch
      return [existing, false] if existing

      carried_over = block_given? ? yield : nil
      if carried_over
        adopt(carried_over)
        return [carried_over, false]
      end

      fresh = SecureRandom.bytes(SESSION_BYTES)
      adopt(fresh)
      [fresh, true]
    end

    # The live session id for this visitor, or nil. Does not create one.
    def existing
      PRIVACY_REDIS_POOL.with do |redis|
        raw = redis.get(key)
        raw && decode(raw)
      end
    end

    private

    # GETEX both reads the session and extends its life in one round trip, so
    # an active visitor's window keeps sliding forward without a second call.
    def touch
      PRIVACY_REDIS_POOL.with do |redis|
        raw = redis.getex(key, ex: Tastatur.session_timeout.to_i)
        raw && decode(raw)
      end
    end

    def adopt(session_hash)
      PRIVACY_REDIS_POOL.with do |redis|
        redis.set(key, encode(session_hash), ex: Tastatur.session_timeout.to_i)
      end
    end

    # Hex rather than raw bytes: Redis values are binary-safe, but keeping the
    # stored form printable makes `redis-cli` debugging of a live ingest path
    # bearable.
    def encode(bytes) = bytes.unpack1("H*")
    def decode(hex) = [hex].pack("H*")

    def key
      "#{KEY_PREFIX}#{@site_id}:#{@visitor_hash.unpack1('H*')}"
    end
  end
end
