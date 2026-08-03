require "rails_helper"

# Every edit screen carries a delete button, and for a while every one of them
# saved the record instead of deleting it.
#
# The cause was `f.actions ..., destructive: button_to(...)`. `button_to`
# renders a <form>, so that put a <form> inside the edit <form>. Nested forms
# are invalid HTML and the parser DISCARDS the inner start tag — measured in
# Chromium, not inferred — which leaves the delete button owned by the edit form
# and its `data-turbo-confirm` on an element that no longer exists. Clicking it
# submitted the edit form: Turbo put `_method=patch` on the wire, Rails ran
# `update`, and the redirect landed back on the record as though nothing had
# happened.
#
# No request spec could catch that, because a request spec issues the clean
# DELETE that no browser was ever going to send. These assertions are about the
# MARKUP: that the page contains no nested form, and that the button is wired to
# a form which actually deletes. See TastaturFormBuilder#actions.
RSpec.describe "Destructive buttons on edit forms", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, account: account, domain: "measured.example.com") }

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  # Walks the tags in order and reports any <form> opened while another is open.
  # Deliberately a scan of the delivered bytes rather than a DOM query: the
  # browser's own parser is what silently repairs this, so anything that parses
  # first would hide exactly the defect being asserted against.
  def nested_form_depth_exceeded?(html)
    depth = 0
    html.scan(%r{</?form\b}) do |tag|
      if tag.start_with?("</")
        depth -= 1
      else
        depth += 1
        return true if depth > 1
      end
    end
    false
  end

  # The button in the actions row, the form it names, and the fact that that
  # form is a DELETE to the record.
  def assert_wired_to_delete(html, label, path)
    button = html[/<button[^>]*>\s*#{Regexp.escape(label)}\s*<\/button>/m]
    expect(button).to be_present, "no #{label.inspect} button on the page"

    form_id = button[/\bform="([^"]+)"/, 1]
    expect(form_id).to be_present,
                       "#{label.inspect} has no form= attribute, so it submits whichever form encloses it"

    form = html[/<form[^>]*\bid="#{Regexp.escape(form_id)}"[^>]*>.*?<\/form>/m]
    expect(form).to be_present, "#{label.inspect} points at ##{form_id}, which is not on the page"
    expect(form).to include(%(action="#{path}"))
    expect(form).to include(%(name="_method" value="delete"))
  end

  # The dashboard IS its own editor now, which puts a rename form, a widget
  # panel and two destructive buttons on one page — so this is the page most
  # able to grow the defect back.
  it "puts no form inside another form on the dashboard" do
    dashboard = create(:dashboard, site: site)

    get site_dashboard_path(site, dashboard)

    expect(nested_form_depth_exceeded?(response.body)).to be(false),
                                                          "a <form> is nested inside another <form>"
    expect(response.body).to include("Delete dashboard")
  end

  it "puts no form inside another form with a widget panel open" do
    dashboard = create(:dashboard, site: site)

    get site_dashboard_path(site, dashboard, configure: dashboard.dashboard_widgets.sole.public_id)

    expect(response.body).to include("Save widget")
    expect(nested_form_depth_exceeded?(response.body)).to be(false),
                                                          "a <form> is nested inside another <form>"
  end

  it "puts no form inside another form on the goal editor" do
    goal = create(:goal, site: site)

    get edit_site_goal_path(site, goal)

    expect(nested_form_depth_exceeded?(response.body)).to be(false),
                                                          "a <form> is nested inside another <form>"
    assert_wired_to_delete(response.body, "Delete", site_goal_path(site, goal))
  end

  it "puts no form inside another form on the funnel editor" do
    funnel = create(:funnel, site: site)

    get edit_site_funnel_path(site, funnel)

    expect(nested_form_depth_exceeded?(response.body)).to be(false),
                                                          "a <form> is nested inside another <form>"
    assert_wired_to_delete(response.body, "Delete funnel", site_funnel_path(site, funnel))
  end

  # The dashboard's own delete is an ordinary button_to on a page with no form
  # around it, so it needs no detached form — but it does still have to carry
  # what the deletion takes with it.
  it "says what else deleting a dashboard revokes" do
    dashboard = create(:dashboard, site: site)
    create(:shared_link, site: site, dashboard: dashboard)

    get site_dashboard_path(site, dashboard)

    form = response.body[/<form[^>]*data-turbo-confirm="[^"]*share link[^"]*"[^>]*>/]
    expect(form).to be_present, "the delete button carries no confirmation"
    expect(form).to include("1 share link")
  end

  it "offers nothing to delete on a new record" do
    get new_site_dashboard_path(site)

    expect(response.body).not_to include("Delete dashboard")
    expect(nested_form_depth_exceeded?(response.body)).to be(false)
  end
end
