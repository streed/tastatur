import { Controller } from "@hotwired/stimulus"

// Reports how the dashboard is used, through the tracker this product ships.
//
// Mounted once on <body>. Clicks and form submissions bubble to it, and it
// matches the nearest annotated ancestor, so every call site is a data
// attribute on the element it describes:
//
//   <a data-analytics-event="Filter Applied"
//      data-analytics-props='{"dimension":"page","position":3}'>
//
// There is no selector list here to fall out of step with the markup, and
// nothing to re-wire when a Turbo Frame replaces half the page.
//
// WHAT MAY GO IN A PROP: the shape of an interaction, never its subject. The
// dimension a filter is on, never the value it matches; which breakdown row by
// position, never what that row says. Those values are a customer's own
// visitors' data — a page path, a referrer, a country somebody was in — and
// copying one into our analytics would make the claims on /privacy false about
// us, which is worse than false about anyone else. Site keys, domains, account
// names and email addresses are out for the same reason.
export default class extends Controller {
  // One step arrives already decided: the server saw a sign-in succeed and put
  // it on this element, because the page the visitor lands on afterwards offers
  // no interaction that says so.
  //
  // The annotation is removed as it is read, which is what keeps the count
  // honest. Turbo snapshots this body for its cache, and a visitor returning to
  // the page from that cache would otherwise report the same sign-in again.
  connect() {
    const name = this.element.dataset.analyticsLoadEvent
    if (!name) return

    const props = this.element.dataset.analyticsLoadProps
    delete this.element.dataset.analyticsLoadEvent
    delete this.element.dataset.analyticsLoadProps

    this.report(name, props)
  }

  track(event) {
    const element = event.target.closest("[data-analytics-event]")
    if (!element) return

    if (event.type === "turbo:submit-end") {
      // Only submissions the server accepted. A form that came back 422 with
      // validation errors created nothing, and counting it would report more
      // goals than exist.
      if (!event.detail?.success) return
    } else if (element.tagName === "FORM") {
      // The click on a submit button bubbles to its form as well. The
      // submission above is the honest place to count it, because it is the
      // only one that knows whether the thing was created.
      return
    }

    this.report(element.dataset.analyticsEvent, element.dataset.analyticsProps)
  }

  report(name, encodedProps) {
    // The tracker is only present when this instance measures itself, which a
    // self-hosted one never does. Its absence is the normal state there, not a
    // fault, so it is a no-op rather than a thrown error in someone's console.
    if (typeof window.tastatur !== "function") return

    const props = encodedProps ? JSON.parse(encodedProps) : null
    window.tastatur("event", name, props ? { props } : undefined)
  }
}
