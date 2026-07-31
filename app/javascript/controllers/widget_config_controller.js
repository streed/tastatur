import { Controller } from "@hotwired/stimulus"

// Shows the configuration section that matches a widget row's chosen kind.
//
// Each section declares the kinds it serves in data-kinds (space-separated);
// everything else is hidden. Purely presentational: without JavaScript every
// section stays visible, the form still submits every field, and
// DashboardWidget#clear_irrelevant_config nulls whatever the chosen kind does
// not use — so hiding here is a courtesy, never the thing correctness rests on.
export default class extends Controller {
  static targets = ["kind", "section"]

  connect() {
    this.refresh()
  }

  kindChanged() {
    this.refresh()
  }

  refresh() {
    const kind = this.kindTarget.value
    this.sectionTargets.forEach((section) => {
      section.hidden = !section.dataset.kinds.split(" ").includes(kind)
    })
  }
}
