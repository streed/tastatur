require "rails_helper"

RSpec.describe "Ingest", type: :request do
  let(:site) { create(:site, domain: "example.com") }
  let(:chrome) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0 Safari/537.36" }

  before do
    delete_all_events
    Ingest::WriteBuffer.clear!
  end

  def post_event(payload, headers = {})
    post "/api/event",
         params: payload.to_json,
         headers: { "CONTENT_TYPE" => "text/plain", "HTTP_USER_AGENT" => chrome }.merge(headers)
  end

  def stored_events
    Ingest::WriteBuffer.flush!
    Event.all.to_a
  end

  describe "a pageview" do
    it "accepts it and stores one event" do
      post_event(s: site.public_token, u: "https://example.com/pricing", w: 1440)

      expect(response).to have_http_status(:accepted)
      expect(stored_events.size).to eq(1)
    end

    it "records the page, source and coarse device profile" do
      post_event(s: site.public_token,
                 u: "https://example.com/pricing?utm_source=hn",
                 r: "https://news.ycombinator.com/item?id=1",
                 w: 1440)

      event = stored_events.first
      expect(event.path).to eq("/pricing")
      expect(event.utm_source).to eq("hn")
      expect(event.referrer_host).to eq("news.ycombinator.com")
      expect(event.referrer_source).to eq("hn"), "an explicit utm_source outranks the referrer"
      expect(event.browser).to eq("Chrome")
      expect(event.device_type).to eq("desktop")
      expect(event.screen_class).to eq("xl")
    end

    it "marks the first event of a visit as the entry" do
      post_event(s: site.public_token, u: "https://example.com/")
      post_event(s: site.public_token, u: "https://example.com/pricing")

      expect(stored_events.count(&:is_entry)).to eq(1)
    end

    it "sets first_event_at so onboarding can stop waiting" do
      expect { post_event(s: site.public_token, u: "https://example.com/") }
        .to change { site.reload.first_event_at }.from(nil)
    end
  end

  describe "what must never be stored" do
    it "keeps no query string beyond utm parameters" do
      post_event(s: site.public_token,
                 u: "https://example.com/reset?token=SUPERSECRET&email=alice@example.com")

      event = stored_events.first
      expect(event.attributes.values.map(&:to_s).join(" ")).not_to include("SUPERSECRET")
      expect(event.attributes.values.map(&:to_s).join(" ")).not_to include("alice@example.com")
    end

    it "strips personal data out of the path itself" do
      post_event(s: site.public_token, u: "https://example.com/users/alice@example.com/settings")
      expect(stored_events.first.path).to eq("/users/:email/settings")
    end

    it "stores no column resembling an IP address or a user-agent string" do
      post_event(s: site.public_token, u: "https://example.com/")
      row = stored_events.first.attributes

      expect(row.keys).not_to include("ip", "ip_address", "user_agent", "remote_addr")
      expect(row.values.map(&:to_s).join(" ")).not_to include("Mozilla/5.0")
    end
  end

  describe "traffic we refuse to count" do
    it "drops a declared crawler" do
      post_event({ s: site.public_token, u: "https://example.com/" },
                 { "HTTP_USER_AGENT" => "Googlebot/2.1 (+http://www.google.com/bot.html)" })

      expect(response).to have_http_status(:accepted)
      expect(stored_events).to be_empty
    end

    it "drops headless automation presenting as a browser" do
      post_event({ s: site.public_token, u: "https://example.com/" },
                 { "HTTP_USER_AGENT" => "Mozilla/5.0 (X11; Linux x86_64) HeadlessChrome/120.0.0.0" })

      expect(stored_events).to be_empty
    end

    it "honours Do Not Track" do
      post_event({ s: site.public_token, u: "https://example.com/" }, { "HTTP_DNT" => "1" })
      expect(stored_events).to be_empty
    end

    # The counter behind the dashboard's "some of your visitors send Do Not Track"
    # footnote. It read the token from `params[:s]`, and the tracker posts with
    # `Content-Type: text/plain` to stay a CORS simple request — which Rails does
    # not parse into `params`. So the counter recorded nothing for the transport
    # carrying essentially all the traffic, and only the noscript pixel, which puts
    # the token in the query string, was ever counted.
    #
    # Undercounting here is worse than having no footnote: a site owner comparing
    # against another tool would be told the unexplained gap was tiny.
    it "counts the opt-out even though the body is text/plain" do
      expect { post_event({ s: site.public_token, u: "https://example.com/" }, { "HTTP_DNT" => "1" }) }
        .to change { Ingest::OptOutCounter.count_for(site, from: 1.hour.ago) }.by(1)
    end

    it "counts a Global Privacy Control opt-out too" do
      expect { post_event({ s: site.public_token, u: "https://example.com/" }, { "HTTP_SEC_GPC" => "1" }) }
        .to change { Ingest::OptOutCounter.count_for(site, from: 1.hour.ago) }.by(1)
    end

    it "counts an opt-out arriving on the pixel path" do
      expect do
        get "/api/pixel?s=#{site.public_token}&u=#{CGI.escape('https://example.com/')}",
            headers: { "HTTP_DNT" => "1", "HTTP_USER_AGENT" => chrome }
      end.to change { Ingest::OptOutCounter.count_for(site, from: 1.hour.ago) }.by(1)
    end

    it "does not count an opt-out for a site token that does not exist" do
      expect do
        post_event({ s: "0" * Site::TOKEN_LENGTH, u: "https://example.com/" }, { "HTTP_DNT" => "1" })
      end.not_to change { Ingest::OptOutCounter.count_for(site, from: 1.hour.ago) }
    end

    it "honours Global Privacy Control" do
      post_event({ s: site.public_token, u: "https://example.com/" }, { "HTTP_SEC_GPC" => "1" })
      expect(stored_events).to be_empty
    end

    it "ignores a browser prefetch, which is not a visit" do
      post_event({ s: site.public_token, u: "https://example.com/" },
                 { "HTTP_SEC_PURPOSE" => "prefetch;prerender" })
      expect(stored_events).to be_empty
    end
  end

  describe "bad input" do
    # Every rejection is a quiet 202. This endpoint runs in a stranger's browser
    # on someone else's website; an error there is noise the site owner cannot
    # act on, and a distinguishable response would let anyone probe which site
    # tokens are valid.
    it "answers 202 for an unknown site token without storing anything" do
      post_event(s: "AAAAAAAAAAAAAAAA", u: "https://example.com/")

      expect(response).to have_http_status(:accepted)
      expect(stored_events).to be_empty
    end

    it "answers 202 for a malformed payload" do
      post "/api/event", params: "not json at all",
                         headers: { "CONTENT_TYPE" => "text/plain", "HTTP_USER_AGENT" => chrome }
      expect(response).to have_http_status(:accepted)
    end

    it "answers 202 for a missing URL" do
      post_event(s: site.public_token)
      expect(response).to have_http_status(:accepted)
      expect(stored_events).to be_empty
    end

    it "rejects an oversized props hash" do
      props = (1..50).to_h { |i| ["key#{i}", "value"] }
      post_event(s: site.public_token, u: "https://example.com/", n: "Custom", p: props)
      expect(stored_events).to be_empty
    end

    it "rejects revenue without a currency, which would mix currencies in one total" do
      post_event(s: site.public_token, u: "https://example.com/", n: "Purchase", v: 4900)
      expect(stored_events).to be_empty
    end
  end

  # The endpoint's central promise is that it looks identical whatever you send
  # it, so nobody can probe it and nobody sees an error in a console about a
  # decision they cannot act on. A query string Rails cannot parse used to break
  # that: `?s=%` answered 400 and logged a full exception report per request.
  #
  # It could not be fixed in the controller. ActionController::Instrumentation
  # parses the query string to build its log payload at the top of
  # `process_action`, before any `rescue_from` is in scope, and Rack::Attack's
  # throttle blocks touch `params` earlier still. Hence
  # Middleware::SanitizeIngestQuery.
  describe "a query string Rails cannot parse" do
    # A note on coverage. Rack::Test builds its request with `URI.parse`, which
    # rejects `%zz` itself before the app is ever called, so the nastiest inputs
    # cannot be expressed as a request spec at all — the harness fails, not the
    # application. Those are covered directly in
    # spec/lib/middleware/sanitize_ingest_query_spec.rb, which drives the Rack env
    # the way a real client can. What is left here is the subset that survives
    # URI.parse and still reached ActionController::BadRequest before the fix.
    {
      "truncated percent escape" => "s=%",
      "unparseable key" => "%=1"
    }.each do |label, query|
      it "answers 202 rather than 400 for a #{label}" do
        post "/api/event?#{query}", headers: { "HTTP_USER_AGENT" => chrome }

        expect(response).to have_http_status(:accepted)
      end
    end

    it "answers 202 for a nesting depth beyond the parser's limit" do
      # 120 levels. ActionDispatch's limit is 100, which is the one that matters
      # here; Rack's own param_depth_limit of 32 is not what raises.
      post "/api/event?a#{(1..120).map { |i| "[#{i}]" }.join}=1", headers: { "HTTP_USER_AGENT" => chrome }

      expect(response).to have_http_status(:accepted)
    end

    it "still returns a GIF from the pixel path" do
      get "/api/pixel?s=%", headers: { "HTTP_USER_AGENT" => chrome }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/gif")
    end

    # Salvaging rather than discarding: only the unparseable pairs are dropped, so
    # a real event is not lost because something appended junk to the URL.
    it "still records an event whose body is valid" do
      post "/api/event?junk=%",
           params: { s: site.public_token, u: "https://example.com/salvaged" }.to_json,
           headers: { "CONTENT_TYPE" => "text/plain", "HTTP_USER_AGENT" => chrome }

      expect(response).to have_http_status(:accepted)
      expect(stored_events.map(&:path)).to eq(["/salvaged"])
    end
  end

  # Redis is on the critical path three times: the rotating salt, the session
  # window, and the write buffer. An outage used to surface as a 500, which is the
  # one response this endpoint must never give — it would print an error in the
  # console of every page of every customer site, about our problem, which they
  # cannot act on. Measured before the fix: stopping the salt Redis turned a valid
  # beacon into a 500.
  describe "when Redis is unreachable" do
    before do
      allow(Ingest::Identifier).to receive(:new).and_raise(Redis::CannotConnectError)
      allow(Sentry).to receive(:capture_exception)
    end

    it "still answers 202" do
      post_event(s: site.public_token, u: "https://example.com/outage")

      expect(response).to have_http_status(:accepted)
    end

    it "still returns a GIF from the pixel path" do
      get "/api/pixel?s=#{site.public_token}&u=#{CGI.escape('https://example.com/outage')}",
          headers: { "HTTP_USER_AGENT" => chrome }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/gif")
    end

    # The response is quiet; the incident is not. A silently dropped event with no
    # trace anywhere would make an outage invisible.
    it "reports the failure rather than swallowing it" do
      post_event(s: site.public_token, u: "https://example.com/outage")

      expect(Sentry).to have_received(:capture_exception).with(instance_of(Redis::CannotConnectError))
    end

    it "reports a Failure so callers can tell it did not store anything" do
      result = Ingest::RecordEvent.call(
        payload: { s: site.public_token, u: "https://example.com/outage" },
        ip: "203.0.113.10",
        user_agent: chrome
      )

      expect(result).to be_failure
      expect(result.failure).to eq(:storage_unavailable)
    end
  end

  describe "custom events" do
    it "stores the name, properties and revenue" do
      post_event(s: site.public_token, u: "https://example.com/checkout", n: "Purchase",
                 p: { "plan" => "growth" }, v: 4900, c: "eur")

      event = stored_events.first
      expect(event.event_name).to eq("Purchase")
      expect(event.props).to eq("plan" => "growth")
      expect(event.revenue_cents).to eq(4900)
      expect(event.currency).to eq("EUR")
    end
  end

  describe "CORS" do
    # Customers must not have to configure anything. The site token is public
    # by construction, so an origin allowlist would protect nothing while
    # breaking staging domains, proxies and embedded iframes.
    it "allows any origin" do
      post_event({ s: site.public_token, u: "https://example.com/" }, { "HTTP_ORIGIN" => "https://anything.test" })
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "answers the preflight" do
      process :options, "/api/event", headers: { "HTTP_ORIGIN" => "https://example.com" }
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "the noscript pixel" do
    it "returns a GIF and records the event" do
      get "/api/pixel", params: { s: site.public_token, u: "https://example.com/no-js" },
                        headers: { "HTTP_USER_AGENT" => chrome }

      expect(response.media_type).to eq("image/gif")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(stored_events.first.path).to eq("/no-js")
    end
  end
end
