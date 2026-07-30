import { Controller } from "@hotwired/stimulus"

// Crosshair and tooltip for the server-rendered SVG timeseries.
//
// The chart itself is complete HTML — this only adds the hover layer. If
// JavaScript never runs, the chart is still there and still readable, which is
// the point of rendering it server-side in the first place.
export default class extends Controller {
  static targets = ["band", "tooltip"]

  connect() {
    this.labels = JSON.parse(this.tooltipTarget.dataset.labels || "[]")
    // "pageviews" normally, "events" when the dashboard is filtered to a
    // custom event and the series carries matching events instead.
    this.volumeLabel = this.tooltipTarget.dataset.volumeLabel || "pageviews"
    this.bandTargets.forEach((band) => {
      band.addEventListener("mouseenter", this.show)
      band.addEventListener("mousemove", this.move)
      band.addEventListener("mouseleave", this.hide)
    })
  }

  disconnect() {
    this.bandTargets.forEach((band) => {
      band.removeEventListener("mouseenter", this.show)
      band.removeEventListener("mousemove", this.move)
      band.removeEventListener("mouseleave", this.hide)
    })
  }

  show = (event) => {
    const { index, visitors, pageviews } = event.currentTarget.dataset

    this.tooltipTarget.innerHTML = `
      <p class="label mb-1.5">${this.labels[index] ?? ""}</p>
      <p class="flex items-center gap-2 num">
        <span class="inline-block w-2.5 h-0.5 bg-signal"></span>
        <span class="font-semibold">${Number(visitors).toLocaleString()}</span>
        <span class="text-muted">visitors</span>
      </p>
      <p class="flex items-center gap-2 num">
        <span class="inline-block w-2.5 h-0.5 bg-petrol"></span>
        <span class="font-semibold">${Number(pageviews).toLocaleString()}</span>
        <span class="text-muted">${this.volumeLabel}</span>
      </p>`

    this.tooltipTarget.classList.remove("hidden")
    event.currentTarget.setAttribute("fill", "rgba(22,21,15,0.035)")
  }

  move = (event) => {
    const box = this.element.getBoundingClientRect()
    const tip = this.tooltipTarget

    // Flip to the left of the cursor near the right edge so the tooltip never
    // pushes the page into a horizontal scroll.
    let left = event.clientX - box.left + 14
    if (left + tip.offsetWidth > box.width) left = event.clientX - box.left - tip.offsetWidth - 14

    tip.style.left = `${Math.max(0, left)}px`
    tip.style.top = `${Math.max(0, event.clientY - box.top - tip.offsetHeight - 12)}px`
  }

  hide = (event) => {
    this.tooltipTarget.classList.add("hidden")
    event.currentTarget.setAttribute("fill", "transparent")
  }
}
