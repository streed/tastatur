module Revenue
  # The shared vocabulary for naming an acquisition channel.
  #
  # THIS EXISTS BECAUSE THE ATTRIBUTION REPORT IS A JOIN BETWEEN TWO PIPELINES
  # THAT NEVER MEET ANYWHERE ELSE, and they join on strings. The visitor count
  # comes from the events hypertable, where a source was classified server-side by
  # Ingest::Referrer. The revenue comes from `customers`, where a source arrived
  # from the customer's own application, which got it from `tastatur.attribution()`
  # in a browser that has never heard of config/referrer_sources.yml.
  #
  # Left alone, those two produce different spellings of the same channel, and the
  # failure is silent and ugly: a visit from Hacker News is counted under "Hacker
  # News" on the traffic side and "news.ycombinator.com" on the revenue side, so
  # the flagship screen shows two rows — one with all the visitors and no money,
  # one with all the money and no visitors. Both are wrong, neither is empty, and
  # nothing raises. The conversion rate reads as 0% for the channel that is
  # actually working.
  #
  # So every source that enters the revenue side is put through the SAME
  # classification the events side already used, at write time. One vocabulary,
  # one place, and `spec/services/revenue/rollup_attribution_spec.rb` asserts a
  # referrer-sourced visit and its customer land on one row.
  module Channel
    # `Ingest::Referrer::DIRECT` rather than a "(direct)" of our own, for exactly
    # the reason above: the events pipeline already writes "Direct" into
    # `referrer_source`, and a second spelling here would split every direct-traffic
    # row in two.
    DIRECT = Ingest::Referrer::DIRECT

    # Medium and campaign have no equivalent in the events pipeline — they exist
    # only as utm parameters — so their sentinel is ours to choose. Bracketed so
    # it cannot collide with a real campaign somebody names "none".
    NONE = "(none)".freeze

    # Customers who predate the Stripe connection. Deliberately NOT merged into
    # DIRECT: "we have no idea, they were here before we were" and "we know, they
    # typed the URL" are different facts, and merging them makes the first month
    # after connecting look like an enormous direct-traffic win.
    PRE_INSTALL = "(pre-install)".freeze

    module_function

    # Normalises one customer's attribution into the events pipeline's vocabulary.
    #
    # `referrer_host` is used ONLY when no explicit source was supplied, which
    # mirrors Ingest::Referrer#source exactly: a UTM tag is an explicit statement
    # by whoever built the link, and the referrer header is only ever a guess.
    def normalize(source: nil, medium: nil, campaign: nil, referrer_host: nil)
      {
        source: resolve_source(source, referrer_host) || DIRECT,
        medium: medium.presence || NONE,
        campaign: campaign.presence || NONE
      }
    end

    # The classified source, or nil when the caller supplied nothing to classify.
    #
    # SEPARATE FROM `normalize` BECAUSE SENTINELS MUST NEVER BE STORED, only
    # displayed. `normalize` is for reading: it fills every field so a report
    # always has something to group by. This is for writing, and the difference
    # is load-bearing.
    #
    # The bug that produced this split: `Revenue::IdentifyCustomer` persisted the
    # output of `normalize`, so the FIRST identify call — which typically carries
    # only a source — wrote "(none)" into `attribution_campaign`. Attribution is
    # write-once, so the column was then no longer blank, and the real campaign
    # arriving on the next call could never fill it. Every customer was
    # permanently attributed to "(none)" for any field their first call happened
    # to omit, and the report looked entirely plausible while being wrong.
    #
    # So writers store only what is genuinely known and leave the rest NULL. The
    # rollup's SQL applies the sentinel with COALESCE/NULLIF, and Customer#attribution
    # applies it in Ruby — both at read time, where it belongs.
    def resolve_source(source, referrer_host)
      # A sentinel passed back in is already resolved. Without this, a re-import
      # would look up "(pre-install)" in the referrer table, miss, and return it
      # unchanged — right by luck, and no longer right the moment that table
      # gained a wildcard.
      return source if source.present? && sentinel?(source)
      return classify(source) if source.present?
      return classify(referrer_host) if referrer_host.present?

      nil
    end

    def sentinel?(value)
      [DIRECT, NONE, PRE_INSTALL].include?(value)
    end

    # Maps a hostname to its friendly name using the same table Ingest::Referrer
    # reads, and leaves anything unrecognised alone.
    #
    # A value that is already a friendly name ("Google") is not a hostname, misses
    # the lookup, and passes through untouched — which is the correct outcome and
    # is why this is a lookup rather than a parse.
    def classify(value)
      host = value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").split("/").first.to_s.sub(/\Awww\./, "")
      return value.to_s.strip if host.blank?

      known = Ingest::Referrer.sources[host]
      return known.first if known

      # A subdomain belongs to whoever owns the parent domain, so
      # news.google.com resolves to Google without needing its own entry. Same
      # walk as Ingest::Referrer#lookup, for the same reason.
      parts = host.split(".")
      parent = (1...parts.length - 1).lazy
                                     .map { |i| Ingest::Referrer.sources[parts[i..].join(".")] }
                                     .find(&:itself)

      parent ? parent.first : value.to_s.strip
    end

    # The SQL expression naming a channel on the EVENTS side, so the raw scan and
    # the customer side cannot drift. `NULLIF(x, '')` because the ingest path
    # writes an empty string for an absent utm parameter in some paths and NULL in
    # others, and COALESCE alone would treat "" as present.
    def events_source_sql
      "COALESCE(NULLIF(utm_source, ''), NULLIF(referrer_source, ''), #{ActiveRecord::Base.connection.quote(DIRECT)})"
    end

    def events_medium_sql
      "COALESCE(NULLIF(utm_medium, ''), #{ActiveRecord::Base.connection.quote(NONE)})"
    end

    def events_campaign_sql
      "COALESCE(NULLIF(utm_campaign, ''), #{ActiveRecord::Base.connection.quote(NONE)})"
    end
  end
end
