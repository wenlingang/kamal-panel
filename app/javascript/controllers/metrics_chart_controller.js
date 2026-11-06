import { Controller } from "@hotwired/stimulus"

// Hover read-out for a server-rendered metrics chart (MetricsHelper#metrics_chart): a vertical
// cursor at the nearest sampled time and a small box listing every series' value there. The data
// comes pre-formatted from the server (units, locale), so this only picks the nearest bucket.
// Text goes in with textContent: series labels are host and container names.
export default class extends Controller {
  static targets = ["plot", "cursor", "tooltip"]
  static values = { data: Object }

  move(event) {
    const data = this.dataValue
    if (!data.x || data.x.length === 0) return

    const svg = this.plotTarget.querySelector("svg")
    const rect = svg.getBoundingClientRect()
    if (rect.width === 0) return

    const position = ((event.clientX - rect.left) / rect.width) * data.width
    const index = this.nearest(data.x, position)
    const x = data.x[index]

    this.cursorTarget.setAttribute("x1", x)
    this.cursorTarget.setAttribute("x2", x)
    this.cursorTarget.removeAttribute("hidden")
    this.render(data, index)

    const left = (x / data.width) * rect.width
    const tooltip = this.tooltipTarget
    tooltip.hidden = false
    // Keep the box inside the plot: flip to the left of the cursor past the middle.
    const flip = left > rect.width / 2
    tooltip.style.left = flip ? "" : `${left}px`
    tooltip.style.right = flip ? `${rect.width - left}px` : ""
  }

  leave() {
    this.cursorTarget.setAttribute("hidden", "")
    this.tooltipTarget.hidden = true
  }

  nearest(xs, position) {
    let best = 0
    for (let i = 1; i < xs.length; i++) {
      if (Math.abs(xs[i] - position) < Math.abs(xs[best] - position)) best = i
    }
    return best
  }

  render(data, index) {
    const box = this.tooltipTarget
    box.replaceChildren()

    const time = document.createElement("div")
    time.className = "chart-tooltip-time"
    time.textContent = data.t[index]
    box.append(time)

    data.s.forEach((series) => {
      const value = series.v[index]
      if (value === null || value === undefined) return

      const row = document.createElement("div")
      row.className = "chart-tooltip-row"
      const label = document.createElement("span")
      label.className = "chart-tooltip-label"
      const swatch = document.createElement("span")
      swatch.className = `chart-tooltip-swatch chart-c-${series.c}`
      label.append(swatch, document.createTextNode(series.l))
      const number = document.createElement("span")
      number.className = "chart-tooltip-value"
      number.textContent = value
      row.append(label, number)
      box.append(row)
    })
  }
}
