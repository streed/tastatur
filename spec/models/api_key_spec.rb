require "rails_helper"

RSpec.describe ApiKey do
  let(:site) { create(:site) }

  describe ".generate!" do
    it "returns an unsaved key carrying its plaintext exactly once" do
      key = described_class.generate!(site: site, name: "production")

      expect(key.plaintext).to start_with("tk_")
      expect(key).not_to be_persisted
      key.save!

      # Reloading is how the rest of the application ever sees this row, and it
      # must never carry the secret. A screen that could re-display a key makes a
      # database read equivalent to holding the credential.
      expect(described_class.find(key.id).plaintext).to be_nil
    end

    it "stores a digest rather than the token" do
      key = described_class.generate!(site: site, name: "production")
      key.save!

      expect(key.token_digest).not_to include(key.plaintext)
      expect(described_class.where(token_digest: key.plaintext)).to be_empty
    end

    it "records the last four characters for identification" do
      key = described_class.generate!(site: site, name: "production")

      expect(key.last_four).to eq(key.plaintext.last(4))
    end
  end

  describe ".authenticate" do
    # THE BUG THIS BLOCK EXISTS FOR. The secret is urlsafe base64, whose alphabet
    # includes the underscore — so splitting the token on "_" without a limit
    # returns four or more parts for roughly half of all generated keys. The
    # failure is intermittent by construction: some keys work, some do not, and
    # re-issuing fixes it half the time.
    it "resolves every generated key, whatever the secret happens to contain" do
      keys = Array.new(25) { |i| described_class.generate!(site: site, name: "key-#{i}").tap(&:save!) }

      keys.each do |key|
        expect(described_class.authenticate(key.plaintext)).to eq(key),
                                                               "failed for #{key.plaintext}"
      end
    end

    it "accepts a token containing underscores in its secret" do
      key = described_class.generate!(site: site, name: "underscored")
      key.token = "tk_#{key.token_prefix}_abc_def_ghi"
      key.save!

      expect(described_class.authenticate("tk_#{key.token_prefix}_abc_def_ghi")).to eq(key)
    end

    it "refuses a wrong secret against a real prefix" do
      key = described_class.generate!(site: site, name: "production")
      key.save!

      expect(described_class.authenticate("tk_#{key.token_prefix}_wrong")).to be_nil
    end

    it "refuses a revoked key" do
      key = described_class.generate!(site: site, name: "production")
      key.save!
      plaintext = key.plaintext
      key.revoke!

      expect(described_class.authenticate(plaintext)).to be_nil
    end

    # Every failure is indistinguishable from every other, for the same reason
    # §12 makes the ingest endpoint always answer 202: a caller that could tell
    # "no such key" from "wrong secret" could enumerate valid prefixes.
    it "returns nil for anything malformed rather than raising" do
      ["", "nonsense", "tk_", "tk_only_two", nil, "bearer tk_a_b"].each do |token|
        expect(described_class.authenticate(token)).to be_nil
      end
    end
  end

  describe "#note_use" do
    it "records the first use" do
      key = create(:api_key, site: site)

      key.note_use
      expect(key.reload.last_used_at).to be_present
    end

    # This runs on every authenticated request. Unthrottled it turns a read-only
    # check into a row update per request, on a row those same requests all read,
    # so they serialise behind each other's locks.
    it "does not write again within the throttle window" do
      key = create(:api_key, site: site)
      key.note_use
      first = key.reload.last_used_at

      key.note_use(at: first + 10.seconds)

      expect(key.reload.last_used_at).to eq(first)
    end

    it "writes again once the window has passed" do
      key = create(:api_key, site: site)
      key.note_use
      first = key.reload.last_used_at

      key.note_use(at: first + 2.minutes)

      expect(key.reload.last_used_at).to be > first
    end
  end

  describe "revocation" do
    # A destroyed key takes with it the answer to "when did this stop working,
    # and was that before or after the incident?"
    it "keeps the row" do
      key = create(:api_key, site: site)

      expect { key.revoke! }.not_to change(described_class, :count)
      expect(key.reload).to be_revoked
    end
  end

  describe "validations" do
    it "requires a name unique within the site" do
      create(:api_key, site: site, name: "production")
      duplicate = described_class.generate!(site: site, name: "production")

      expect(duplicate).not_to be_valid
    end

    it "allows the same name on another site" do
      create(:api_key, site: site, name: "production")

      expect(described_class.generate!(site: create(:site), name: "production")).to be_valid
    end
  end
end
