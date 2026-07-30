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
export default class extends Controller {
  static targets = ["rows", "template", "addButton", "count"]
  static values = { max: { type: Number, default: 0 }, min: { type: Number, default: 0 } }

  connect() {
    this.refresh()
  }

  add(event) {
    event.preventDefault()
    if (this.atMax) return

    // A timestamp keeps indices unique across repeated adds without having to
    // track a counter that could collide with a server-rendered index.
    const html = this.templateTarget.innerHTML.replace(/NEW_RECORD/g, Date.now().toString())
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
      if (label) label.textContent = `Step ${index + 1}`

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

  get visibleRows() {
    return Array.from(this.rowsTarget.querySelectorAll("[data-nested-form-row]"))
                .filter((row) => !row.hidden)
  }

  get atMax() {
    return this.maxValue > 0 && this.visibleRows.length >= this.maxValue
  }
}
