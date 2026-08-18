import { Controller } from "@hotwired/stimulus"

// Shows the tagged URL the form is about to save, as it is typed.
//
// A PREVIEW OF A SERVER-SIDE TRUTH, not a second implementation of it. The URL
// that gets copied from a saved link, listed on the report and quoted anywhere
// else comes from CampaignLink#url; this exists so the box is not empty and
// stale while somebody fills the form in. The two agree on the awkward parts —
// a destination that already carries a query string or a fragment, and blank
// optional values being left out rather than emitted empty — and a request spec
// pins the server half against the same cases.
//
// Fields are read by their `name` attribute rather than through targets. The
// three UTM comboboxes are built by TastaturFormBuilder#combobox, which
// composes its own `data` hash for them, so a `data-campaign-builder-target`
// passed alongside would be replaced rather than merged and the preview would
// silently stop tracking those three fields — which are the three that matter.
export default class extends Controller {
  static targets = ["output"]

  // Kept in the order the query string should come out in, which is the order
  // CampaignLink::PARAMS declares and the order every UTM link anyone has seen
  // is written in. Not alphabetical: `utm_campaign` first reads as a mistake.
  static PARAMS = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]

  connect() {
    this.render()
  }

  render() {
    if (!this.hasOutputTarget) return

    const built = this.build()
    // An unparseable destination leaves whatever the server last rendered in
    // place rather than blanking the box mid-word: someone halfway through
    // typing "https:/" has not made a mistake yet.
    if (built !== null) this.outputTarget.textContent = built
  }

  build() {
    const destination = this.valueOf("destination_url")
    if (!destination) return null

    let url
    try {
      url = new URL(destination)
    } catch {
      return null
    }

    // Ours win over anything the pasted destination already carried, and the
    // fragment is left where URL put it — at the end, after the query. A UTM
    // value written after a `#` is never sent to the server at all.
    this.constructor.PARAMS.forEach((param) => {
      const value = this.valueOf(param)
      if (value) url.searchParams.set(param, value)
      else url.searchParams.delete(param)
    })

    return url.toString()
  }

  // The form is nested under a model name, so the field is `campaign_link[utm_source]`.
  valueOf(param) {
    const field = this.element.querySelector(`[name$="[${param}]"]`)
    return field ? field.value.trim() : ""
  }
}
