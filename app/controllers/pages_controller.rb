class PagesController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[home about faq llms]
  # The landing page is genuinely public and touches no records, so there is
  # nothing to authorize. Noted explicitly because CLAUDE.md requires a stated
  # reason whenever Pundit verification is skipped.
  skip_after_action :verify_authorized

  # /about and /llms.txt are public information and stay readable before
  # first-run setup, like the other informational pages. The root path
  # deliberately does NOT: on a fresh self-hosted install, sending the operator
  # to the setup wizard is the helpful thing to do.
  always_reachable only: %i[about faq llms]

  def about; end

  # The FAQ. Public, and public in both formats for the same reason the docs
  # are: the most common reason somebody reads it is to decide whether to use
  # Tastatur at all, and increasingly that somebody is an agent answering the
  # question on a person's behalf.
  #
  # The entries come from Seo::Faq rather than from either template, so the HTML
  # page, the markdown rendering and the FAQPage JSON-LD in the layout are three
  # renderings of one catalogue. A FAQPage whose structured answers differ from
  # its visible ones is treated as cloaking, and hand-maintaining two copies is
  # how that happens by accident.
  def faq
    @entries = Seo::Faq.entries

    respond_to do |format|
      format.html
      format.md
    end
  end

  # The llms.txt index for AI agents. Its format is pinned to markdown by the
  # route, so there is nothing to negotiate here; the template is what matters.
  def llms; end

  def home
    # A signed-in visitor almost never wants the marketing page.
    return redirect_to sites_path if user_signed_in?

    # HTML for people; markdown for machine readers that ask with
    # `Accept: text/markdown`. Same content, none of the layout.
    respond_to do |format|
      format.html
      format.md
    end
  end

  # `/dashboard` exists because the starter template and Devise's default
  # after-sign-in path both point at it. There is no account-wide dashboard —
  # stats are always per-site — so it forwards to the site list.
  def dashboard
    redirect_to sites_path
  end
end
