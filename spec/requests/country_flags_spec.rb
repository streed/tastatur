require "rails_helper"

# The country breakdown draws a flag from the country code itself — two regional
# indicator letters that an emoji font composes into one flag glyph. That works
# by itself on macOS and on Linux and NOT ON WINDOWS, where Segoe UI Emoji ships
# no flag glyphs at all and covers the two letters individually, so the browser
# never falls through to another family and draws two boxed capitals instead.
#
# The fix is a 76KB webfont covering exactly that range, listed FIRST in the
# font stack. Both halves are load-bearing and neither is visible from Ruby,
# which is why they are pinned here: a spec that only rendered the panel would
# have passed throughout the entire period Windows readers saw no flags.
RSpec.describe "Country flags", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, :no_suppression, account: account) }

  # Read from the SOURCE, not app/assets/builds: the build is a generated
  # artefact that is not in the repository and is rebuilt at deploy.
  let(:stylesheet) { Rails.root.join("app/assets/tailwind/application.css").read }
  let(:font_stack) { stylesheet[/--font-sans:\s*([^;]+);/m, 1].to_s.squish }

  describe "the shipped font" do
    it "is vendored rather than fetched from a CDN" do
      # A privacy product that phones a font CDN on the dashboard would be
      # making a request on the customer's behalf to somebody we do not control.
      expect(Rails.root.join("app/assets/fonts/twemoji-country-flags.woff2")).to exist
      expect(stylesheet).to include('src: url("twemoji-country-flags.woff2")')
    end

    # Without the range the browser downloads 76KB on every page. With it, only
    # a page that actually contains a flag pays.
    it "is gated to the regional indicator range" do
      face = stylesheet[/@font-face\s*\{[^}]*Tastatur Flags.*?\}/m]

      expect(face).to include("unicode-range: U+1F1E6-1F1FF")
    end

    # THE HALF THAT IS EASY TO UNDO WITHOUT NOTICING. Anywhere later in the list
    # and Windows never reaches it: Segoe UI Emoji claims the two letters, so
    # fallback stops there and the flag is two boxed capitals again.
    it "is first in the font stack, ahead of every system emoji family" do
      expect(font_stack).to start_with('"Tastatur Flags"')
    end
  end

  describe "the panel" do
    before do
      create(:membership, account: account, user: user, role: "owner")
      sign_in user
    end

    it "renders a flag beside each country" do
      create_event(site, visitor: "v1", path: "/", country_code: "US", at: 1.hour.ago)
      create_event(site, visitor: "v2", path: "/", country_code: "DE", at: 1.hour.ago)

      get "/sites/#{site.to_param}"

      expect(response.body).to include("\u{1F1FA}\u{1F1F8}</span>United States")
      expect(response.body).to include("\u{1F1E9}\u{1F1EA}</span>Germany")
    end

    # The flag is decoration and the name is the answer, so a reader whose
    # browser cannot draw the glyph still has a readable row — and a screen
    # reader is never handed "flag of Germany, Germany".
    it "hides the flag from assistive technology rather than describing it twice" do
      create_event(site, visitor: "v1", path: "/", country_code: "US", at: 1.hour.ago)

      get "/sites/#{site.to_param}"

      expect(response.body).to include(%(<span class="mr-2" aria-hidden="true">\u{1F1FA}\u{1F1F8}</span>))
    end

    # An event with no country resolves to no flag at all, not to a pair of
    # letters that happen to compose one.
    it "renders no flag for an unknown country" do
      create_event(site, visitor: "v1", path: "/", country_code: nil, at: 1.hour.ago)

      get "/sites/#{site.to_param}"

      expect(response.body).to include(%(<span class="mr-2" aria-hidden="true"></span>Unknown))
    end
  end
end
