import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { application } from "controllers/application"

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
//
// The server's signal, <turbo-stream action="live_refresh" target="…">, goes straight to this
// controller on the target element. Registered here, next to the only thing that handles it;
// controllers are eager-loaded, so this runs before any stream can arrive.
Turbo.StreamActions.live_refresh = function () {
  this.targetElements.forEach((element) => {
    application.getControllerForElementAndIdentifier(element, "live-refresh")?.signal()
  })
}

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
      // Hidden while waiting: keep the signal pending, visibilitychange picks it up.
      if (document.hidden) return
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
      const freshIds = [ ...fresh.querySelectorAll("[data-live-refresh-target~='region']") ].map((el) => el.id)
      const currentIds = this.regionTargets.map((region) => region.id)

      // The page changed shape (first app onboarded, last one filtered away…): regions can't be
      // matched up, so fall back to one ordinary (morphing) Turbo refresh. Rare, unlike the per-round updates.
      if (freshIds.join() !== currentIds.join()) {
        Turbo.visit(window.location.href, { action: "replace" })
        return
      }

      this.regionTargets.forEach((region) => {
        Turbo.morphChildren(region, fresh.getElementById(region.id))
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
