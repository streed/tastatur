import { Controller } from "@hotwired/stimulus"

// Pick a goal's or a funnel step's match value from what the site has actually
// recorded, instead of typing it and hoping.
//
// The controller goes on an element that contains BOTH the `kind` control and
// the combobox, because the two are one question: "pageview" means the value is
// a path and "event" means it is a custom event name, and the list has to swap
// when that changes. On the goal form that element is the form; on a funnel it
// is a single step row, of which there may be eight, each with its own kind.
//
// Options are read from one <script type="application/json"> elsewhere on the
// page, named by `sourceValue`. Eight step rows sharing one payload is the
// reason for the indirection — see OffersKnownValues.
//
// The input is never constrained to the list. Free text is the common case for
// a goal on a page that has not launched yet, and wildcard matchers like
// `/blog/**` are patterns that by definition never appear in recorded data.
export default class extends Controller {
  static targets = ["input", "list", "toggle", "kind"]
  static values = {
    source: String,
    group: { type: String, default: "pageview" },
    // Rendering every one of a large site's paths on each keystroke is fine for
    // the browser and useless for the reader. The list says how many it is not
    // showing rather than pretending this is all of them.
    visible: { type: Number, default: 50 }
  }

  connect() {
    this.options = this.readOptions()
    this.activeIndex = -1
    this.matches = []

    // Nothing recorded yet, or everything withheld by the site's privacy
    // threshold. The field stays a perfectly ordinary text input and the form
    // explains the absence in prose; a control that opens onto nothing is worse
    // than no control.
    if (!this.hasAnyOptions) return

    this.syncGroup()
    if (this.hasToggleTarget) this.toggleTarget.hidden = false

    // Clicking or tabbing anywhere outside closes the list. Scoped to the
    // combobox rather than to this.element, which on the goal form is the whole
    // form — a list left hanging open while someone types into the field below
    // it is the same bug as one that will not close at all. Bound once so it can
    // be removed again: a funnel form adds and removes these rows.
    this.combobox = this.inputTarget.closest(".combobox") || this.element
    this.dismiss = (event) => {
      if (!this.combobox.contains(event.target)) this.close()
    }
    document.addEventListener("click", this.dismiss)
    document.addEventListener("focusin", this.dismiss)
  }

  disconnect() {
    if (!this.dismiss) return
    document.removeEventListener("click", this.dismiss)
    document.removeEventListener("focusin", this.dismiss)
  }

  // --- Reading the payload --------------------------------------------------

  readOptions() {
    const source = this.sourceValue && document.getElementById(this.sourceValue)
    if (!source) return {}

    try {
      return JSON.parse(source.textContent)
    } catch {
      // A malformed payload must not take the form down with it. The field
      // still works; it just stops suggesting.
      return {}
    }
  }

  get currentOptions() {
    return this.options[this.groupValue] || []
  }

  get hasAnyOptions() {
    return Object.values(this.options).some((list) => list.length > 0)
  }

  // --- Kind ----------------------------------------------------------------

  kindChanged() {
    this.syncGroup()
    // The typed value is deliberately left alone. Switching kind by accident and
    // losing what you had written is a worse outcome than a stale-looking field,
    // and the value may well be right for both.
    if (this.expanded) this.render()
  }

  // Radios (the goal form) and a <select> (a funnel step, a dashboard filter
  // pair) both arrive here as kind targets; only a checked radio speaks for
  // the group.
  //
  // The group is normally the control's own value ("pageview" / "event"), but
  // a select whose values are NOT group names — the dashboard filter's
  // dimension select — tags each option with data-group instead, and the
  // selected option's tag wins when present.
  syncGroup() {
    const control = this.kindTargets.find((el) => el.type !== "radio" || el.checked)
    if (!control) return

    this.groupValue = control.selectedOptions?.[0]?.dataset?.group ?? control.value
  }

  // --- Opening and closing --------------------------------------------------

  // Focus. Deliberately not the same as "show me the list": tabbing through a
  // saved funnel's eight steps should not pop open eight dropdowns whose only
  // row is the value already sitting in the field. The toggle, an arrow key and
  // typing all bypass this.
  open() {
    if (!this.hasAnyOptions) return
    // A group with no options — a dashboard filter on Country, say, whose
    // values the payload does not carry — stays a plain text field on focus
    // rather than opening onto a "nothing recorded" note about a list that was
    // never going to exist. The toggle and ArrowDown still show the note,
    // which also covers the funnel case of a site with paths but no events.
    if (this.currentOptions.length === 0) return
    if (this.currentOptions.some((option) => option.v === this.inputTarget.value)) return
    this.render()
  }

  filter() {
    if (!this.hasAnyOptions) return
    this.activeIndex = -1
    this.render()
  }

  toggle(event) {
    // mousedown rather than click, with the default prevented, so pressing the
    // button never takes focus off the input — losing it would close the list
    // being asked for.
    event.preventDefault()
    if (this.expanded) {
      this.close()
    } else {
      this.inputTarget.focus()
      this.activeIndex = -1
      this.render({ all: true })
    }
  }

  close() {
    this.listTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.activeIndex = -1
  }

  get expanded() {
    return !this.listTarget.hidden
  }

  // --- Keyboard -------------------------------------------------------------

  navigate(event) {
    switch (event.key) {
      case "ArrowDown":
        if (!this.hasAnyOptions) return
        event.preventDefault()
        // render, not open: asking for the list explicitly always gets it.
        if (!this.expanded) return this.render()
        this.moveActive(1)
        break
      case "ArrowUp":
        // Only swallowed when there is a list to walk. Otherwise this is still
        // the browser's "move the caret to the start of the field".
        if (!this.expanded) return
        event.preventDefault()
        this.moveActive(-1)
        break
      case "Enter":
        // Only swallowed when it is choosing something. With no option
        // highlighted, Enter still submits the form as it always did.
        if (this.expanded && this.activeIndex >= 0) {
          event.preventDefault()
          this.commit(this.matches[this.activeIndex].v)
        } else {
          this.close()
        }
        break
      case "Escape":
        if (this.expanded) {
          event.preventDefault()
          this.close()
        }
        break
      case "Tab":
        this.close()
        break
    }
  }

  moveActive(step) {
    const last = this.matches.length - 1
    if (last < 0) return

    // -1 means "still in the text field", which is not index -1 in a wrap: from
    // there, down goes to the first option and up goes to the last. Folding that
    // into the modulo instead sends the first ArrowUp to the second-from-last
    // option, which reads as the list skipping a row.
    if (this.activeIndex < 0) {
      this.activeIndex = step > 0 ? 0 : last
    } else {
      this.activeIndex = (this.activeIndex + step + this.matches.length) % this.matches.length
    }

    this.paintActive()
  }

  // --- Choosing -------------------------------------------------------------

  choose(event) {
    // mousedown, and prevented, for the same reason as the toggle: a click on an
    // option would otherwise blur the input first.
    event.preventDefault()
    this.commit(event.currentTarget.dataset.value)
  }

  commit(value) {
    this.inputTarget.value = value
    this.close()
    this.inputTarget.focus()
  }

  // --- Rendering ------------------------------------------------------------

  render({ all = false } = {}) {
    const query = all ? "" : this.inputTarget.value.trim()
    const found = this.search(query)

    // `matches` is the RENDERED subset, not everything that matched. The arrow
    // keys index into it, so an option that was cut by the cap must not be
    // reachable — highlighting a row that is not on screen is how a listbox
    // ends up committing a value nobody saw.
    this.matches = found.slice(0, this.visibleValue)
    if (this.activeIndex >= this.matches.length) this.activeIndex = -1

    this.listTarget.replaceChildren(
      ...this.matches.map((option, index) => this.optionElement(option, index)),
      ...this.footer(query, found.length - this.matches.length)
    )

    this.listTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
    this.paintActive()
  }

  // Substring, case-insensitive, ranked so that what you are most likely to have
  // started typing comes first. Within a rank the order is the one the server
  // sent, which is most-visited first — the best default for an empty query.
  search(query) {
    if (query === "") return this.currentOptions

    const needle = query.toLowerCase()
    const ranked = []

    this.currentOptions.forEach((option) => {
      const haystack = option.v.toLowerCase()
      if (haystack === needle) ranked.push([0, option])
      else if (haystack.startsWith(needle)) ranked.push([1, option])
      else if (haystack.includes(needle)) ranked.push([2, option])
    })

    return ranked.sort((a, b) => a[0] - b[0]).map(([, option]) => option)
  }

  optionElement(option, index) {
    const item = document.createElement("li")
    item.id = `${this.listTarget.id}-option-${index}`
    item.className = "combobox-option"
    item.setAttribute("role", "option")
    item.setAttribute("aria-selected", "false")
    item.dataset.value = option.v
    item.dataset.action = "mousedown->value-picker#choose"

    const value = document.createElement("span")
    value.className = "combobox-value"
    // textContent, not innerHTML: these strings are paths and event names from
    // somebody else's website.
    value.textContent = option.v

    const count = document.createElement("span")
    count.className = "combobox-count num"
    count.textContent = option.n.toLocaleString()

    item.append(value, count)
    return item
  }

  // Not options, so neither carries role="option" and neither is reachable with
  // the arrow keys.
  footer(query, remaining) {
    const notes = []

    if (this.matches.length === 0) {
      notes.push(
        query === ""
          ? "Nothing recorded for this kind yet."
          : `No match for "${query}". It will be saved exactly as typed.`
      )
    } else if (remaining > 0) {
      notes.push(`${remaining.toLocaleString()} more — keep typing to narrow them down.`)
    }

    return notes.map((text) => {
      const note = document.createElement("li")
      note.className = "combobox-note"
      note.textContent = text
      return note
    })
  }

  paintActive() {
    const items = Array.from(this.listTarget.querySelectorAll("[role=option]"))

    items.forEach((item, index) => {
      const active = index === this.activeIndex
      item.setAttribute("aria-selected", active ? "true" : "false")
      item.classList.toggle("is-active", active)
      if (active) {
        this.inputTarget.setAttribute("aria-activedescendant", item.id)
        item.scrollIntoView({ block: "nearest" })
      }
    })

    if (this.activeIndex < 0) this.inputTarget.removeAttribute("aria-activedescendant")
  }
}
