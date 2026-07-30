require "rails_helper"

RSpec.describe Compliance::LookupOwnData do
  let(:site) { create(:site) }
  let(:ip) { "203.0.113.77" }
  let(:user_agent) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0 Safari/537.36" }

  def hash_under(salt)
    Ingest::Identifier
      .new(site_id: site.id, ip: ip, user_agent: user_agent)
      .send(:digest, salt)
      .unpack1("H*")
  end

  def record(path, salt, at:)
    create_event(site, path: path, at: at, visitor_hash: hash_under(salt), session_hash: hash_under(salt))
  end

  def findings
    described_class.call(ip: ip, user_agent: user_agent).value_or(nil)&.findings.to_a
  end

  before do
    Ingest::SaltStore.destroy_all!
    Ingest::SaltStore.current
  end

  it "finds an event recorded under the current salt" do
    record("/now", Ingest::SaltStore.current, at: 1.hour.ago)

    expect(findings.map(&:path)).to eq(["/now"])
  end

  # The gap this closes. The search window is 48 hours, which spans two salt
  # generations, but only the current salt's digest was ever computed — so
  # everything written before the last rotation was unreachable. Someone
  # exercising their access right an hour after rotation was told we held nothing
  # about them, while their rows from that morning sat in the table under the
  # previous salt.
  #
  # An access request answered "nothing" when the answer is "these fourteen rows"
  # is a wrong answer, and it fails in the direction that looks like the privacy
  # design working.
  context "after the salt has rotated" do
    before do
      record("/before-rotation", Ingest::SaltStore.current, at: 3.hours.ago)
      Ingest::SaltStore.rotate!
    end

    it "still finds the event written under the previous salt" do
      expect(findings.map(&:path)).to include("/before-rotation")
    end

    it "finds events from both generations together" do
      record("/after-rotation", Ingest::SaltStore.current, at: 1.minute.ago)

      expect(findings.map(&:path)).to contain_exactly("/before-rotation", "/after-rotation")
    end

    it "reports the identifier the caller carries now, not the retired one" do
      result = described_class.call(ip: ip, user_agent: user_agent).value!

      expect(result.visitor_hash_hex).to eq(hash_under(Ingest::SaltStore.current))
      expect(result.visitor_hash_hex).not_to eq(hash_under(Ingest::SaltStore.previous))
    end
  end

  # The other half of the promise: once a salt is destroyed the data derived from
  # it is unreachable, and the page shows that rather than asserting it.
  it "cannot find an event whose salt has been destroyed" do
    record("/ancient", Ingest::SaltStore.current, at: 3.hours.ago)
    Ingest::SaltStore.rotate!
    Ingest::SaltStore.rotate! # the original salt is now gone entirely

    expect(findings.map(&:path)).not_to include("/ancient")
  end

  it "finds nothing for a connection that has never been seen" do
    record("/someone-else", Ingest::SaltStore.current, at: 1.hour.ago)

    other = described_class.call(ip: "198.51.100.9", user_agent: user_agent).value!

    expect(other.findings).to be_empty
  end

  it "fails cleanly when there is no connection to derive an identity from" do
    expect(described_class.call(ip: nil, user_agent: user_agent)).to be_failure
  end
end
