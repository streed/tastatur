import { Controller } from "@hotwired/stimulus"

// Refreshes the enclosing Turbo Frame on an interval.
//
// Used by the "waiting for your first pageview" card. Polling stops on its own
// once the server renders the success state, because that markup simply does not
// include this controller — there is no flag to clear and no way to leave a
// timer running after the wait is over.
//
// The frame's response MUST contain a matching <turbo-frame> element. If it does
// not, Turbo empties the frame rather than reporting an error, and the card
// vanishes as though the wait had succeeded. See the partial for the fix.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 5000 } }

  connect() {
    this.frame = this.element.closest("turbo-frame")
    if (!this.frame) return

    this.timer = setInterval(() => this.tick(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  tick() {
    // A background tab polling forever is a pointless load on the server and on
    // the user's battery.
    if (document.visibilityState !== "visible") return

    if (this.frame.getAttribute("src") !== this.urlValue) {
      // Assigning src is itself what triggers the fetch, so this branch must not
      // also call reload() — that would issue two requests for one tick.
      this.frame.setAttribute("src", this.urlValue)
    } else {
      this.frame.reload()
    }
  }
}
