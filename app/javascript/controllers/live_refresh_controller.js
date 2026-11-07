import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Keeps parts of a page live without refreshing the page.
//
// The server only sends a signal ("something changed", see OverviewSignal): it can't render the
// fragments itself, because they depend on who is looking (the filter in their URL, the actions
// their role allows). On a signal this controller fetches its own current URL in the background
// and morphs just the region targets (matched by id) — no Turbo visit, so no progress bar, no
// scroll jump, and controls outside the regions (the filter box someone may be typing in) are
// never touched.
//
// Signals arrive once per app per polling round, so they are coalesced: at most one fetch in
// flight, at most one per minInterval, and none while the tab is hidden (a pending signal is
// caught up on when it becomes visible again).
export default class extends Controller {
  static targets = ["region"]
  static values = { minInterval: { type: Number, default: 5000 } }

  connect() {
    this.lastRun = 0
    this.onVisibility = () => { if (!document.hidden && this.pending) this.schedule() }
    document.addEventListener("visibilitychange", this.onVisibility)
  }

  disconnect() {
    clearTimeout(this.timer)
    this.timer = null
    this.request?.abort()
    document.removeEventListener("visibilitychange", this.onVisibility)
  }

  signal() {
    this.pending = true
    this.schedule()
  }

  schedule() {
    if (this.timer || this.inFlight || document.hidden) return

    const wait = Math.max(0, this.lastRun + this.minIntervalValue - Date.now())
    this.timer = setTimeout(() => {
      this.timer = null
      this.reload()
    }, wait)
  }

  async reload() {
    this.pending = false
    this.inFlight = true
    this.lastRun = Date.now()
    this.request = new AbortController()

    try {
      const response = await fetch(window.location.href, {
        headers: { Accept: "text/html" },
        credentials: "same-origin",
        signal: this.request.signal
      })
      // Signed out or an error page: leave what is shown; the next navigation deals with it.
      if (!response.ok || response.redirected) return

      const fresh = new DOMParser().parseFromString(await response.text(), "text/html")
      this.regionTargets.forEach((region) => {
        const replacement = fresh.getElementById(region.id)
        if (replacement) Turbo.morphChildren(region, replacement)
      })
    } catch (error) {
      if (error.name !== "AbortError") console.warn("[live-refresh]", error)
    } finally {
      this.inFlight = false
      this.request = null
      if (this.pending && this.element.isConnected) this.schedule()
    }
  }
}
