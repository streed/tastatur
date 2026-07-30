require "rails_helper"

RSpec.describe "The FAQ", type: :request do
  describe "GET /faq" do
    it "is public, and readable without an account" do
      get "/faq"

      expect(response).to have_http_status(:ok)
    end

    it "renders every question in the catalogue as its own anchored heading" do
      get "/faq"
      doc = Nokogiri::HTML(response.body)

      Seo::Faq.entries.each do |entry|
        section = doc.at_css("section##{entry.anchor}")

        expect(section).to be_present, "no section for #{entry.anchor}"
        expect(section.at_css("h2").text).to include(entry.question)
      end
    end

    # An answer split across a heading boundary is an answer an extractor cannot
    # quote. Every paragraph of an entry has to live inside that entry's own
    # section, which is what makes the anchor worth deep-linking to.
    it "keeps each answer inside its own section" do
      get "/faq"
      doc = Nokogiri::HTML(response.body)

      Seo::Faq.entries.each do |entry|
        text = doc.at_css("section##{entry.anchor}").text

        entry.answer.each { |paragraph| expect(text).to include(paragraph) }
      end
    end

    it "stays reachable before first-run setup, like the other public documents" do
      allow(Tastatur).to receive(:needs_first_run_setup?).and_return(true)

      get "/faq"

      expect(response).to have_http_status(:ok)
    end

    # Unlike the marketing page, the FAQ does not bounce a signed-in reader to
    # their sites. Somebody who already has an account is exactly the person who
    # comes here to look up whether they need a DPA.
    it "is still readable once you have an account" do
      sign_in create(:user)

      get "/faq"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the markdown rendering" do
    it "is served at /faq.md" do
      get "/faq.md"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/markdown")
      expect(response.body).to start_with("# Tastatur — frequently asked questions")
    end

    it "is served by negotiation for a machine reader" do
      get "/faq", headers: { "Accept" => "text/markdown" }

      expect(response.media_type).to eq("text/markdown")
      expect(response.body).not_to include("<div")
    end

    it "still serves HTML to a browser" do
      get "/faq", headers: { "Accept" => "text/html,application/xhtml+xml,*/*;q=0.8" }

      expect(response.media_type).to eq("text/html")
    end

    # MARKDOWN IS WHITESPACE-SENSITIVE AND ERB EATS WHITESPACE. Rails trims any
    # line holding nothing but a scriptlet tag, newline included — correct for
    # HTML, and quietly fatal here: paragraphs emitted one per line through a
    # loop arrive with nothing between them, and every consumer then renders one
    # run-on paragraph instead of three. It still looks like a valid document, it
    # still contains every word, and only the structure is gone. Which is the
    # structure a machine reader came for.
    it "separates paragraphs with a blank line, so they stay separate paragraphs" do
      get "/faq.md"
      body = response.body

      Seo::Faq.entries.each do |entry|
        expect(body).to include(entry.answer.join("\n\n")), "#{entry.anchor} runs its answer together"
      end
    end

    it "puts a blank line before every heading" do
      get "/faq.md"

      response.body.lines.each_cons(2) do |before, line|
        next unless line.start_with?("#")

        expect(before.strip).to eq(""), "heading #{line.strip.inspect} is glued to the line above"
      end
    end

    # An ERB comment ends at the first closing delimiter inside it, so a comment
    # that shows an example tag terminates early and prints its own remainder
    # into the document — above the H1, where llms.txt has just told an agent to
    # expect a title. The same trap is called out in crawlers/sitemap.xml.erb.
    it "begins at the title, with no template commentary above it" do
      get "/faq.md"

      expect(response.body.lines.first).to eq("# Tastatur — frequently asked questions\n")
    end

    # THE POINT OF Seo::Faq BEING A CATALOGUE. Three renderings, one source: if
    # somebody softens an answer in the HTML page only, this fails. The JSON-LD
    # half of the same guarantee is in
    # spec/services/seo/build_structured_data_spec.rb.
    it "carries the same questions and answers as the HTML page" do
      get "/faq.md"
      markdown = response.body

      Seo::Faq.entries.each do |entry|
        expect(markdown).to include("## #{entry.question}")
        entry.answer.each { |paragraph| expect(markdown).to include(paragraph) }
      end
    end
  end

  describe "the pricing question" do
    it "quotes the catalogue rather than a number typed into the copy" do
      get "/faq"

      expect(response.body).to include("$#{Billing::Plan.pro.price_display} a month")
      expect(response.body).to include(
        ActiveSupport::NumberHelper.number_to_delimited(Billing::Plan.free.monthly_event_limit)
      )
    end

    # Same reasoning as /pricing being absent from the sitemap and llms.txt where
    # billing is off: quoting a price an instance cannot charge is an offer that
    # fails at the button. The rest of the page is unaffected.
    it "disappears where this instance cannot take money, and takes nothing else with it" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(false)

      get "/faq"

      expect(response.body).not_to include("a month for")
      expect(response.body).to include("Do I need a cookie banner")
      expect(Nokogiri::HTML(response.body).at_css("section#pricing")).to be_nil
    end
  end

  it "is linked from the pages a reader arrives on" do
    { "/" => "Common questions", "/privacy" => "FAQ", "/docs" => "Common questions" }
      .each do |path, _label|
        get path

        expect(response.body).to include('href="/faq"'), "#{path} does not link the FAQ"
      end
  end
end
