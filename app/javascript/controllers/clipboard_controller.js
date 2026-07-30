import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "label"]

  async copy(event) {
    event.preventDefault()

    try {
      await navigator.clipboard.writeText(this.sourceTarget.textContent.trim())
      this.confirm("Copied")
    } catch {
      // Clipboard access is denied outside a secure context, which includes
      // plain-http staging environments. Selecting the text is a usable
      // fallback and better than a silent no-op.
      this.select()
      this.confirm("Press ⌘C / Ctrl+C")
    }
  }

  select() {
    const range = document.createRange()
    range.selectNodeContents(this.sourceTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }

  confirm(message) {
    const original = this.labelTarget.textContent
    this.labelTarget.textContent = message
    setTimeout(() => { this.labelTarget.textContent = original }, 2000)
  }
}
