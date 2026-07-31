import { Controller } from "@hotwired/stimulus"

// Add and remove a widget's saved-filter rows.
//
// Deliberately NOT nested-form: filter pairs are value objects that
// DashboardWidget#filter_pairs_attributes= rebuilds wholesale from every
// submission — there is no child record, so there is no _destroy to set and a
// removed row is simply deleted from the DOM. A separate controller is also
// what keeps the outer widget list honest: nested_form_controller counts rows
// with querySelectorAll("[data-nested-form-row]"), which would descend into
// any inner rows sharing that attribute and corrupt the widget count.
export default class extends Controller {
  static targets = ["rows", "template"]

  add(event) {
    event.preventDefault()

    const html = this.templateTarget.innerHTML.replace(/NEW_PAIR/g, Date.now().toString())
    this.rowsTarget.insertAdjacentHTML("beforeend", html)

    const rows = this.rowsTarget.querySelectorAll("[data-filter-pairs-row]")
    rows[rows.length - 1]?.querySelector("select")?.focus()
  }

  remove(event) {
    event.preventDefault()
    event.target.closest("[data-filter-pairs-row]")?.remove()
  }
}
