require "rails_helper"

RSpec.describe Analytics::PageFlow do
  let(:site) { create(:site, :no_suppression) }
  let(:period) { Analytics::Period.parse("30d", site: site) }

  before { delete_all_events }

  def flow(prefix, direction: :forward, filters: Analytics::Filters.new, **opts)
    described_class.call(site: site, period: period, prefix: prefix,
                         direction: direction, filters: filters, **opts).value!
  end

  # One visit is one session. `visitor` defaults to the session name so a spec
  # that does not care about the distinction gets one visitor per visit.
  def visit(session, paths, base: 3.hours.ago, visitor: session, **attrs)
    paths.each_with_index do |path, index|
      create_event(site, visitor: visitor, session: session, path: path,
                        is_entry: index.zero?, at: base + index.minutes, **attrs)
    end
  end

  # One custom event, on the page the visit is already on.
  def fire(session, name, base: 3.hours.ago, offset: 0, path: "/", visitor: session)
    create_event(site, visitor: visitor, session: session, path: path,
                      event_name: name, at: base + offset)
  end

  def branch(result, path)
    result.branches.find { |b| !b.terminal? && b.step == Analytics::FlowStep.page(path) }
  end

  def event_branch(result, name)
    result.branches.find { |b| !b.terminal? && b.step == Analytics::FlowStep.event(name) }
  end

  def terminal(result)
    result.branches.find(&:terminal?)
  end

  describe "walking forward" do
    it "counts the page seen immediately next" do
      visit("s1", ["/", "/pricing"])
      visit("s2", ["/", "/pricing"])
      visit("s3", ["/", "/docs"])

      result = flow(["/"])
      expect(result.visitors).to eq(3)
      expect(branch(result, "/pricing").visitors).to eq(2)
      expect(branch(result, "/docs").visitors).to eq(1)
    end

    # THE CASE THAT SEPARATES THIS REPORT FROM A FUNNEL, and the one a
    # well-meaning "reuse FunnelReport's chained CTE" refactor would break.
    #
    # A funnel step is satisfied by a match anywhere later in the visit. If this
    # report worked that way, the visitor below would be counted under BOTH the
    # /docs branch and the /pricing branch of the same node, the branches would
    # sum past the node's own visitor count, and the percentages would exceed
    # 100% — at which point it is not a flow diagram, it is a co-occurrence table
    # drawn like one.
    it "does not count a page reached later but not next" do
      visit("s1", ["/", "/docs", "/pricing"])

      result = flow(["/"])
      expect(branch(result, "/docs").visitors).to eq(1)
      expect(branch(result, "/pricing")).to be_nil
    end

    it "keeps the branches summing to the node's own visitor count" do
      visit("s1", ["/", "/pricing"])
      visit("s2", ["/", "/docs"])
      visit("s3", ["/"])

      result = flow(["/"])
      expect(result.branches.sum(&:visitors)).to eq(result.visitors)
      expect(result.branches.sum(&:percentage).round).to eq(100)
    end

    it "chains to an arbitrary depth" do
      visit("s1", ["/", "/pricing", "/checkout"])
      visit("s2", ["/", "/pricing", "/checkout"])
      visit("s3", ["/", "/pricing", "/faq"])

      result = flow(["/", "/pricing"])
      expect(result.visitors).to eq(3)
      expect(branch(result, "/checkout").visitors).to eq(2)
      expect(branch(result, "/faq").visitors).to eq(1)
    end

    it "anchors on the first arrival when the page recurs" do
      # Reaches /pricing twice. The journey through it starts at the first.
      visit("s1", ["/", "/pricing", "/docs", "/pricing", "/checkout"])

      expect(branch(flow(["/pricing"]), "/docs").visitors).to eq(1)
      expect(branch(flow(["/pricing"]), "/checkout")).to be_nil
    end
  end

  describe "the branch that leaves the tree" do
    it "reports visits that ended on the page" do
      visit("s1", ["/", "/pricing"])
      visit("s2", ["/"])
      visit("s3", ["/"])

      result = flow(["/"])
      expect(terminal(result).visitors).to eq(2)
      expect(terminal(result).percentage).to eq(66.7)
    end

    # An INNER JOIN would drop these rows silently, which would not merely lose
    # the "left the site" row — it would inflate every other percentage on the
    # panel, because the denominator stays the node's full visitor count.
    it "does not distort the surviving branches" do
      visit("s1", ["/", "/pricing"])
      3.times { |i| visit("end#{i}", ["/"]) }

      result = flow(["/"])
      expect(result.visitors).to eq(4)
      expect(branch(result, "/pricing").percentage).to eq(25.0)
    end
  end

  describe "walking backward" do
    it "counts the page seen immediately before" do
      visit("s1", ["/", "/pricing"])
      visit("s2", ["/docs", "/pricing"])

      result = flow(["/pricing"], direction: :backward)
      expect(branch(result, "/").visitors).to eq(1)
      expect(branch(result, "/docs").visitors).to eq(1)
    end

    it "reports visits that began on the page" do
      visit("s1", ["/pricing", "/checkout"])

      expect(terminal(flow(["/pricing"], direction: :backward)).visitors).to eq(1)
    end

    it "falls back to forward for an unknown direction" do
      visit("s1", ["/", "/pricing"])

      expect(flow(["/"], direction: :sideways).direction).to eq(:forward)
    end
  end

  describe "repeated views of one page" do
    # A reload is not navigation. Left uncollapsed, the most common "next page"
    # for every page on a site is itself — true, and useless.
    it "treats consecutive views as a single step" do
      visit("s1", ["/", "/", "/", "/pricing"])

      result = flow(["/"])
      expect(branch(result, "/")).to be_nil
      expect(branch(result, "/pricing").visitors).to eq(1)
    end

    # Collapsing must not swallow a genuine return: these are not consecutive.
    it "keeps a return to a page visited earlier" do
      visit("s1", ["/", "/pricing", "/"])

      expect(branch(flow(["/", "/pricing"]), "/").visitors).to eq(1)
    end
  end

  describe "session grain" do
    it "does not join two separate visits by the same visitor" do
      # Same person, two sittings. The second visit's first page is not the
      # "next page" after the first visit's last one.
      visit("s1", ["/"], visitor: "same", base: 5.hours.ago)
      visit("s2", ["/pricing"], visitor: "same", base: 1.hour.ago)

      result = flow(["/"])
      expect(branch(result, "/pricing")).to be_nil
      expect(terminal(result).visitors).to eq(1)
    end

    # A visit spanning the site's local midnight holds TWO visitor_hashes for one
    # person, because the salt rotates underneath it while Ingest::Identifier
    # carries the session across (CLAUDE.md §13). Anchoring with GROUP BY
    # (session_hash, visitor_hash) rather than DISTINCT ON (session_hash) emits
    # that session once per hash, and the visit is walked — and counted — twice.
    it "counts a visit that spans a salt rotation once" do
      create_event(site, session: "s1", visitor: "before", path: "/",        at: 3.hours.ago, is_entry: true)
      create_event(site, session: "s1", visitor: "before", path: "/docs",    at: 3.hours.ago + 1.minute)
      create_event(site, session: "s1", visitor: "after",  path: "/",        at: 3.hours.ago + 2.minutes)
      create_event(site, session: "s1", visitor: "after",  path: "/pricing", at: 3.hours.ago + 3.minutes)

      result = flow(["/"])
      expect(result.branches.sum(&:sessions)).to eq(1)
      expect(branch(result, "/docs").sessions).to eq(1)
      expect(branch(result, "/pricing")).to be_nil
    end
  end

  describe "custom events" do
    # The default, and what Analytics::Dashboard's two flow panels rely on:
    # they are titled "The page before this one" and would otherwise answer a
    # different question than they ask.
    it "ignores them as steps unless asked for" do
      visit("s1", ["/"])
      fire("s1", "Signup", offset: 30.seconds)
      create_event(site, session: "s1", visitor: "s1", path: "/pricing",
                        at: 3.hours.ago + 1.minute)

      expect(branch(flow(["/"]), "/pricing").visitors).to eq(1)
      expect(event_branch(flow(["/"]), "Signup")).to be_nil
    end

    it "counts them as steps when asked for" do
      visit("s1", ["/"])
      fire("s1", "Signup", offset: 30.seconds)

      result = flow(["/"], include_events: true)
      expect(result.visitors).to eq(1)
      expect(event_branch(result, "Signup").visitors).to eq(1)
    end

    # The whole point of including them: the event goes BETWEEN the two pages,
    # so the page after it is no longer the page immediately after "/". A report
    # that placed both there would be counting one visitor twice, which is the
    # co-occurrence bug this service exists to avoid.
    it "sits between the pages it happened between" do
      visit("s1", ["/"])
      fire("s1", "Signup", offset: 30.seconds)
      create_event(site, session: "s1", visitor: "s1", path: "/welcome",
                        at: 3.hours.ago + 1.minute)

      level = flow(["/"], include_events: true)
      expect(event_branch(level, "Signup").visitors).to eq(1)
      expect(branch(level, "/welcome")).to be_nil

      deeper = flow(["/", Analytics::FlowStep.event("Signup")], include_events: true)
      expect(branch(deeper, "/welcome").visitors).to eq(1)
    end

    it "walks a journey that starts at an event" do
      visit("s1", ["/"])
      fire("s1", "Signup", offset: 30.seconds)
      create_event(site, session: "s1", visitor: "s1", path: "/welcome",
                        at: 3.hours.ago + 1.minute)

      result = flow([Analytics::FlowStep.event("Signup")], include_events: true)
      expect(branch(result, "/welcome").visitors).to eq(1)
    end

    it "reports a visit that ended on an event" do
      visit("s1", ["/"])
      fire("s1", "Signup", offset: 30.seconds)

      deeper = flow(["/", Analytics::FlowStep.event("Signup")], include_events: true)
      expect(terminal(deeper).visitors).to eq(1)
    end

    # THE KIND IS TESTED INSIDE EACH BRANCH, which is the rule CLAUDE.md §12
    # states for funnel-step conditions and which matters here for the same
    # reason: a customer is free to name an event after the page it leads to,
    # and matching on the value alone would make the two the same step.
    it "does not let an event satisfy a step that asked for the page" do
      visit("s1", ["/"])
      fire("s1", "/welcome", offset: 30.seconds)
      create_event(site, session: "s1", visitor: "s1", path: "/pricing",
                        at: 3.hours.ago + 1.minute)

      level = flow(["/"], include_events: true)
      expect(event_branch(level, "/welcome").visitors).to eq(1)
      expect(branch(level, "/welcome")).to be_nil

      as_a_page = flow(["/", Analytics::FlowStep.page("/welcome")], include_events: true)
      expect(as_a_page.visitors).to be_zero
    end

    it "does not collapse an event into a page of the same name" do
      create_event(site, session: "s1", visitor: "s1", path: "/signup",
                        at: 3.hours.ago, is_entry: true)
      fire("s1", "/signup", path: "/signup", offset: 30.seconds)

      expect(event_branch(flow(["/signup"], include_events: true), "/signup").visitors).to eq(1)
    end

    # A double-clicked button is not two steps, for the same reason a reload is
    # not two pages.
    it "treats consecutive repeats of one event as a single step" do
      visit("s1", ["/"])
      fire("s1", "Ping", offset: 10.seconds)
      fire("s1", "Ping", offset: 20.seconds)
      fire("s1", "Ping", offset: 30.seconds)
      create_event(site, session: "s1", visitor: "s1", path: "/pricing",
                        at: 3.hours.ago + 1.minute)

      level = flow(["/", Analytics::FlowStep.event("Ping")], include_events: true)
      expect(event_branch(level, "Ping")).to be_nil
      expect(branch(level, "/pricing").visitors).to eq(1)
    end

    # A click event and the pageview it fired on arrive in separate beacons and
    # land on the same occurred_at often enough to matter. The tiebreak in
    # STEP_ORDER puts the page first, because a page has to be open before
    # anything can happen on it — without it the order is whatever the planner
    # happens to produce, and the two window functions can disagree.
    it "orders an event after the pageview it ties with" do
      at = 3.hours.ago
      create_event(site, session: "s1", visitor: "s1", path: "/", at: at, is_entry: true)
      fire("s1", "Signup", base: at)
      create_event(site, session: "s1", visitor: "s1", path: "/pricing", at: at + 1.minute)

      level = flow(["/"], include_events: true)
      expect(event_branch(level, "Signup").visitors).to eq(1)
      expect(branch(level, "/pricing")).to be_nil
    end
  end

  describe "filters" do
    # Applying the filter per-event rather than per-session is not merely wrong
    # here, it is degenerate: every session would be left holding nothing but its
    # /pricing hits, so every visit would appear to start and end on that page
    # and the report would be structurally empty. Scope#session_qualified_conditions
    # is what prevents it — the same rule Analytics::Summary follows.
    it "selects sessions rather than events" do
      visit("s1", ["/", "/pricing", "/checkout"])
      visit("s2", ["/", "/docs"])

      result = flow(["/"], filters: Analytics::Filters.new({ "page" => "/pricing" }))
      expect(result.visitors).to eq(1)
      expect(branch(result, "/pricing").visitors).to eq(1)
      expect(branch(result, "/docs")).to be_nil
    end
  end

  describe "k-anonymity" do
    let(:site) { create(:site, k_anonymity_threshold: 3) }

    # TWO branches below the threshold, deliberately. With only one, the
    # complementary rule below takes a second as well and nothing survives — see
    # the next example, which is that case on purpose.
    it "withholds a branch below the threshold" do
      4.times { |i| visit("big#{i}", ["/", "/pricing"]) }
      visit("small", ["/", "/secret"])
      visit("other", ["/", "/private"])

      result = flow(["/"])
      expect(branch(result, "/pricing").visitors).to eq(4)
      expect(branch(result, "/secret")).to be_nil
      expect(branch(result, "/private")).to be_nil
      expect(result.suppressed_rows).to eq(2)
      expect(result.suppressed_visitors).to eq(2)
    end

    # Complementary suppression. With the node total on screen, one withheld
    # branch is recoverable as total - the visible ones, so a second must go too.
    # See Analytics::Suppression.
    it "withholds a second branch when only one falls below" do
      4.times { |i| visit("big#{i}", ["/", "/pricing"]) }
      3.times { |i| visit("mid#{i}", ["/", "/docs"]) }
      visit("small", ["/", "/secret"])

      result = flow(["/"])
      expect(result.suppressed_rows).to eq(2)
      expect(branch(result, "/docs")).to be_nil
      expect(branch(result, "/pricing")).not_to be_nil
    end

    it "reports the threshold it applied" do
      visit("s1", ["/", "/pricing"])

      expect(flow(["/"]).threshold).to eq(3)
    end

    it "applies none when the site has opted out" do
      site.update!(k_anonymity_threshold: 0)
      visit("s1", ["/", "/pricing"])

      expect(flow(["/"]).suppressed_rows).to be_zero
      expect(branch(flow(["/"]), "/pricing")).not_to be_nil
    end
  end

  describe "isolation" do
    it "ignores another site's traffic" do
      other = create(:site, :no_suppression)
      create_event(other, session: "x", visitor: "x", path: "/", at: 1.hour.ago, is_entry: true)
      create_event(other, session: "x", visitor: "x", path: "/pricing", at: 1.hour.ago + 1.minute)

      expect(flow(["/"]).visitors).to be_zero
    end

    it "ignores events outside the reporting period" do
      visit("s1", ["/", "/pricing"], base: 90.days.ago)

      expect(flow(["/"]).visitors).to be_zero
    end
  end

  describe "bounds" do
    it "refuses an empty path" do
      expect(described_class.call(site: site, period: period, prefix: [])).to eq(
        Dry::Monads::Failure(:no_start_page)
      )
    end

    it "refuses a path of only blanks" do
      expect(described_class.call(site: site, period: period, prefix: ["", nil])).to eq(
        Dry::Monads::Failure(:no_start_page)
      )
    end

    it "truncates a path deeper than MAX_DEPTH" do
      visit("s1", ["/"])

      result = flow(["/"] * (described_class::MAX_DEPTH + 4))
      expect(result.prefix.size).to eq(described_class::MAX_DEPTH)
    end

    it "caps the branches returned" do
      6.times { |i| visit("s#{i}", ["/", "/p#{i}"]) }

      expect(flow(["/"], limit: 2).branches.size).to eq(2)
    end
  end
end
