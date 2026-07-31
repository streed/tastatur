require "rails_helper"

RSpec.describe Revenue::AppOAuth do
  # Real Net::HTTPResponse instances rather than doubles: `exchange` classifies
  # with `case response when Net::HTTPSuccess`, and === matches the class of a
  # genuine instance, not what a double claims to be.
  def http_response(klass, code, body)
    klass.new("1.1", code, "").tap do |response|
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
    end
  end

  def stub_post(response)
    allow(described_class).to receive(:post_token_request).and_return(response)
  end

  it "returns the parsed token payload on success" do
    stub_post(http_response(Net::HTTPOK, "200",
                            { stripe_user_id: "acct_9", livemode: false, scope: "stripe_apps" }.to_json))

    expect(described_class.exchange(code: "ac_1")).to include(stripe_user_id: "acct_9", scope: "stripe_apps")
  end

  # The double-click case: the code was already exchanged. Stripe answers 4xx
  # with an OAuth error body, whose human half is the message worth surfacing.
  it "raises Refused with the error_description on a 4xx" do
    stub_post(http_response(Net::HTTPBadRequest, "400",
                            { error: "invalid_grant", error_description: "This authorization code was already used." }.to_json))

    expect { described_class.exchange(code: "ac_1") }
      .to raise_error(described_class::Refused, "This authorization code was already used.")
  end

  it "falls back to the error code when there is no description" do
    stub_post(http_response(Net::HTTPBadRequest, "400", { error: "invalid_grant" }.to_json))

    expect { described_class.exchange(code: "ac_1") }
      .to raise_error(described_class::Refused, "invalid_grant")
  end

  it "raises Unavailable on a 5xx" do
    stub_post(http_response(Net::HTTPBadGateway, "502", "<html>bad gateway</html>"))

    expect { described_class.exchange(code: "ac_1") }
      .to raise_error(described_class::Unavailable, /502/)
  end

  # Valid JSON that is not an object — a bare string, an array — parses without
  # error and then explodes on [:key] unless the parse guard rejects it.
  it "treats a valid-JSON non-object body as empty" do
    stub_post(http_response(Net::HTTPOK, "200", '"a string"'))

    expect(described_class.exchange(code: "ac_1")).to eq({})
  end

  # DNS failure is Socket::ResolutionError, which is a SocketError and NOT a
  # SystemCallError — the suite's closed-port guard raises ECONNREFUSED and
  # can never cover this class, so it is pinned here explicitly.
  it "maps a DNS failure to Unavailable" do
    allow(described_class).to receive(:post_token_request)
      .and_raise(SocketError, "getaddrinfo: Name or service not known")

    expect { described_class.exchange(code: "ac_1") }.to raise_error(described_class::Unavailable)
  end

  # The suite's no-network guard points Stripe.api_base at a closed local port;
  # deriving the exchange URL from it means a forgotten stub lands here — a
  # fast, named failure instead of a real HTTPS request to Stripe.
  it "maps a transport failure to Unavailable, quickly" do
    expect { described_class.exchange(code: "ac_1") }.to raise_error(described_class::Unavailable)
  end
end
