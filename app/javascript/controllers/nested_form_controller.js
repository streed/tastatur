import { Controller } from "@hotwired/stimulus"

// Add and remove rows in a Rails nested form, with no build step and no library.
//
// The rows come from a <template>, whose contents a browser never submits, so the
// blank prototype cannot reach the server. Adding clones it and replaces the
// placeholder index with a unique one; Rails then treats each row as a separate
// nested record.
//
// Removing distinguishes two cases, which is the part that is easy to get wrong:
//
//   - A row that was never saved is deleted from the DOM outright. There is
//     nothing on the server to tell about it.
//   - A row that exists in the database is HIDDEN and its `_destroy` field set to
//     1, because the server has to be told to delete it. Removing it from the DOM
//     instead would simply omit it from the submission, and Rails leaves omitted
//     nested records untouched — so the row would quietly come back.
//
// ONE OF THESE NESTS INSIDE ANOTHER: a funnel is a list of steps, and each step
// is a list of alternatives that satisfy it. Stimulus already scopes targets and
// actions to the nearest controller of the same identifier, so the outer
// instance does not steal the inner one's <template> — but `visibleRows` walks
// the DOM itself and has to do that filtering by hand, or a step's alternatives
// are counted as steps and "Step 3" ends up labelling an OR branch.
export default class extends Controller {
  static targets = ["rows", "template", "addButton", "count"]
  static values = {
    max: { type: Number, default: 0 },
    min: { type: Number, default: 0 },
    // What a row is called in its position label — "Step 2", "Widget 2".
    label: { type: String, default: "Step" },
    // A set of alternatives is not a sequence: its first row reads "Matches" and
    // every later one reads "or", with no numbering, because "or 2" is not a
    // thing anybody means.
    firstLabel: { type: String, default: "" },
    numbered: { type: Boolean, default: true },
    // The string the <template> uses where the row index goes. Nested lists need
    // two different ones: the outer add replaces its own placeholder throughout
    // the cloned markup, and would consume the inner one on the way past.
    placeholder: { type: String, default: "NEW_RECORD" }
  }

  connect() {
    this.refresh()
  }

  add(event) {
    event.preventDefault()
    if (this.atMax) return

    // A timestamp keeps indices unique across repeated adds without having to
    // track a counter that could collide with a server-rendered index.
    const html = this.templateTarget.innerHTML.split(this.placeholderValue).join(Date.now().toString())
    this.rowsTarget.insertAdjacentHTML("beforeend", html)
    this.refresh()

    const added = this.visibleRows[this.visibleRows.length - 1]
    added?.querySelector("input[type=text]")?.focus()
  }

  remove(event) {
    event.preventDefault()
    const row = event.target.closest("[data-nested-form-row]")
    if (!row) return

    const destroyField = row.querySelector("input[name*='_destroy']")

    if (destroyField) {
      destroyField.value = "1"
      row.hidden = true
    } else {
      row.remove()
    }

    this.refresh()
  }

  // Keeps the visible step numbers, the button state and the hint in step with
  // whatever is currently on screen.
  refresh() {
    this.visibleRows.forEach((row, index) => {
      const label = row.querySelector("[data-nested-form-position]")
      if (label) label.textContent = this.positionLabel(index)

      // Below the minimum there is nothing safe to remove, so the control is
      // hidden rather than offered and then rejected by the server.
      const remove = row.querySelector("[data-nested-form-remove]")
      if (remove) remove.hidden = this.visibleRows.length <= this.minValue
    })

    if (this.hasAddButtonTarget) {
      this.addButtonTarget.hidden = this.atMax
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = String(this.visibleRows.length)
    }
  }

  positionLabel(index) {
    const text = index === 0 && this.firstLabelValue ? this.firstLabelValue : this.labelValue
    return this.numberedValue ? `${text} ${index + 1}` : text
  }

  // Only the rows this instance owns. A nested list's rows are descendants of
  // this one's rows container too, so querySelectorAll alone would return a
  // funnel's steps AND every alternative inside them. `closest` names the
  // controller each row actually belongs to.
  //
  // Rows inside a <template> never appear here at all: its contents live in a
  // separate document fragment, which is also what keeps the prototype out of
  // the submission.
  get visibleRows() {
    return Array.from(this.rowsTarget.querySelectorAll("[data-nested-form-row]"))
                .filter((row) => row.closest('[data-controller~="nested-form"]') === this.element)
                .filter((row) => !row.hidden)
  }

  get atMax() {
    return this.maxValue > 0 && this.visibleRows.length >= this.maxValue
  }
}
