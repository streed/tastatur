module Compliance
  # Answers "what do you have on me?" by looking, live, rather than asserting.
  #
  # GDPR Art.11(1) says that where a controller can demonstrate it is not in a
  # position to identify a data subject, the access and portability rights in
  # Arts.15–20 do not apply. That is our situation — but replying to a person
  # with a citation and nothing else reads as evasion, and Art.11(2) explicitly
  # invites them to supply information that would let us find them.
  #
  # So we do the search. The visitor loads this page from the same device and
  # network they browse from; we recompute the same HMAC the ingest path would
  # compute, from the live connection, and show them every row that matches.
  #
  # Why this is safe:
  #   - It takes NO user-supplied input. You cannot type in someone else's IP
  #     and read their data, because the value comes from the TCP connection.
  #   - Source addresses cannot be meaningfully spoofed over a completed TCP
  #     handshake, so it is not an oracle against anyone else.
  #   - It writes nothing. The IP used for the lookup is not persisted here any
  #     more than it is during ingest.
  #
  # It also demonstrates the retention claim instead of asking to be believed:
  # a visitor who was on a measured site last week sees an empty result, and
  # that is the honest, verifiable consequence of the salt having been
  # destroyed.
  class LookupOwnData < ApplicationService
    Finding = Struct.new(:site_domain, :occurred_at, :path, :country_code,
                         :browser, :os, :device_type, keyword_init: true)

    Result = Struct.new(:findings, :visitor_hash_hex, :salt_window_hours, keyword_init: true) do
      def any? = findings.any?
    end

    def initialize(ip:, user_agent:)
      @ip = ip
      @user_agent = user_agent
    end

    def call
      return Failure(:no_connection_details) if @ip.blank?

      # BOTH LIVE SALTS, not just the current one.
      #
      # The search below covers 48 hours, which spans two salt generations, but this
      # used to compute the digest from `SaltStore.current` alone — so every event
      # written before the last rotation was unreachable and the older half of the
      # window could never match anything. Someone exercising their access right an
      # hour after rotation was told we held nothing about them, while rows from
      # their session that morning sat in the table under the previous salt.
      #
      # That is a wrong answer to a subject-access request, and it fails in the
      # direction that looks like the privacy claim working, which is why it needed
      # measuring rather than assuming.
      salts = [Ingest::SaltStore.current, Ingest::SaltStore.previous].compact.uniq
      return Success(empty_result) if salts.empty?

      # The hash is site-scoped, so there is one candidate per site per live salt.
      # On a small install that is a handful; the lookup is bounded by the recent
      # chunks either way.
      sites = Site.pluck(:id, :domain)
      return Success(empty_result) if sites.empty?

      candidates = sites.flat_map do |site_id, domain|
        identity = Ingest::Identifier.new(site_id: site_id, ip: @ip, user_agent: @user_agent)
        salts.map { |salt| [site_id, domain, identity.send(:digest, salt)] }
      end

      Success(
        Result.new(
          findings: findings_for(candidates),
          # The identifier they carry *now*, which is the one worth showing them.
          visitor_hash_hex: current_hash_for(sites.first).unpack1("H*"),
          salt_window_hours: 24
        )
      )
    end

    private

    def empty_result
      Result.new(findings: [], visitor_hash_hex: nil, salt_window_hours: 24)
    end

    def current_hash_for(site)
      site_id, = site
      Ingest::Identifier
        .new(site_id: site_id, ip: @ip, user_agent: @user_agent)
        .send(:digest, Ingest::SaltStore.current)
    end

    def findings_for(candidates)
      conditions = candidates.map { "(site_id = ? AND visitor_hash = ?)" }.join(" OR ")
      binds = candidates.flat_map do |site_id, _domain, hash|
        [site_id, ActiveRecord::Type::Binary::Data.new(hash)]
      end

      domains = candidates.to_h { |site_id, domain, _| [site_id, domain] }

      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array(
          [<<~SQL, *binds, 48.hours.ago]
            SELECT site_id, occurred_at, path, country_code, browser, os, device_type
            FROM events
            WHERE (#{conditions}) AND occurred_at >= ?
            ORDER BY occurred_at DESC
            LIMIT 500
          SQL
        )
      )

      rows.map do |row|
        Finding.new(
          site_domain: domains[row["site_id"]],
          occurred_at: row["occurred_at"],
          path: row["path"],
          country_code: row["country_code"],
          browser: row["browser"],
          os: row["os"],
          device_type: row["device_type"]
        )
      end
    end
  end
end
