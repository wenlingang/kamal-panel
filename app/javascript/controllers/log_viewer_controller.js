import { Controller } from "@hotwired/stimulus"

// The log results' view toggles and follow mode.
//
// Toggles (only errors/warnings, line wrap) are classes on this element, which sits outside the
// results frame so they survive a reload of the results; they are mirrored into the page URL so a
// shared link opens the same view.
//
// Follow mode asks the results endpoint every few seconds for the lines after the newest one shown
// (since = that line's timestamp, seen = the keys of the lines at exactly that instant, which
// docker's inclusive --since sends again and the server drops). New rows are appended; the oldest
// are dropped beyond maxRows; the view scrolls along only if the reader is already at the bottom.
// It pauses while the tab is hidden and stops when the page goes away (disconnect).
export default class extends Controller {
  static targets = ["output", "count", "empty", "status", "followButton", "problemsButton", "wrapButton"]
  static values = {
    url: String,
    interval: { type: Number, default: 3000 },
    maxRows: { type: Number, default: 5000 },
    followingText: String,
    pausedText: String,
    limitedText: String,
    failedText: String
  }

  connect() {
    this.following = false
    this.timer = null
    this.inFlight = null

    const params = new URLSearchParams(window.location.search)
    this.setProblems(params.get("problems") === "1")
    this.setWrap(params.get("nowrap") !== "1")

    this.onVisibility = () => {
      if (!this.following) return
      if (document.hidden) {
        this.clearTimer()
        this.showStatus(this.pausedTextValue)
      } else {
        this.showStatus(this.followingTextValue)
        this.schedule(0)
      }
    }
    document.addEventListener("visibilitychange", this.onVisibility)
  }

  disconnect() {
    this.following = false
    this.clearTimer()
    this.inFlight?.abort()
    document.removeEventListener("visibilitychange", this.onVisibility)
  }

  // A fresh set of results replaced the frame: start at the newest line.
  loaded() {
    this.scrollToBottom()
  }

  toggleProblems() {
    this.setProblems(!this.element.classList.contains("only-problems"))
    this.mirrorToUrl("problems", this.element.classList.contains("only-problems") ? "1" : null)
  }

  toggleWrap() {
    const wrap = this.element.classList.contains("nowrap")
    this.setWrap(wrap)
    this.mirrorToUrl("nowrap", wrap ? null : "1")
  }

  toggleFollow() {
    this.following = !this.following
    this.followButtonTarget.setAttribute("aria-pressed", String(this.following))
    this.followButtonTarget.classList.toggle("is-on", this.following)

    if (this.following) {
      this.showStatus(this.followingTextValue)
      this.scrollToBottom()
      this.schedule(this.intervalValue)
    } else {
      this.clearTimer()
      this.inFlight?.abort()
      this.showStatus("")
    }
  }

  setProblems(on) {
    this.element.classList.toggle("only-problems", on)
    if (this.hasProblemsButtonTarget) this.problemsButtonTarget.setAttribute("aria-pressed", String(on))
  }

  setWrap(on) {
    this.element.classList.toggle("nowrap", !on)
    if (this.hasWrapButtonTarget) this.wrapButtonTarget.setAttribute("aria-pressed", String(on))
  }

  mirrorToUrl(name, value) {
    const url = new URL(window.location.href)
    if (value === null) url.searchParams.delete(name)
    else url.searchParams.set(name, value)
    window.history.replaceState(window.history.state, "", url)
  }

  schedule(delay) {
    this.clearTimer()
    if (!this.following || document.hidden) return
    this.timer = setTimeout(() => this.poll(), delay)
  }

  clearTimer() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  async poll() {
    if (!this.following || !this.hasOutputTarget) return this.schedule(this.intervalValue)

    const output = this.outputTarget
    const url = new URL(this.urlValue, window.location.href)
    url.searchParams.set("since", output.dataset.cursor)
    if (output.dataset.seen) url.searchParams.set("seen", output.dataset.seen)
    url.searchParams.set("follow", "1")

    this.inFlight = new AbortController()
    try {
      const response = await fetch(url, {
        headers: { Accept: "text/html" },
        credentials: "same-origin",
        signal: this.inFlight.signal
      })

      if (response.status === 429) {
        this.showStatus(this.limitedTextValue)
      } else if (!response.ok) {
        this.showStatus(this.failedTextValue)
      } else {
        this.append(await response.text())
        this.showStatus(this.followingTextValue)
      }
    } catch (error) {
      if (error.name === "AbortError") return
      this.showStatus(this.failedTextValue)
    } finally {
      this.inFlight = null
    }

    this.schedule(this.intervalValue)
  }

  // The batch is our own server's HTML, log text already escaped there (LogsHelper); a <template>
  // parses it inertly, nothing in it runs.
  append(html) {
    const template = document.createElement("template")
    template.innerHTML = html
    const batch = template.content.querySelector("[data-log-batch]")
    if (!batch || !this.hasOutputTarget) return

    const output = this.outputTarget
    const atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 24
    const rows = Array.from(batch.children)

    output.dataset.cursor = batch.dataset.cursor
    output.dataset.seen = batch.dataset.seen || ""
    if (rows.length === 0) return

    if (this.hasEmptyTarget) this.emptyTarget.remove()
    output.append(...rows)

    const excess = output.querySelectorAll(".log-row").length - this.maxRowsValue
    if (excess > 0) {
      output.querySelectorAll(".log-row").forEach((row, index) => { if (index < excess) row.remove() })
    }

    if (this.hasCountTarget) {
      this.countTarget.textContent = output.querySelectorAll(".log-row").length
    }
    if (atBottom) this.scrollToBottom()
  }

  scrollToBottom() {
    if (this.hasOutputTarget) this.outputTarget.scrollTop = this.outputTarget.scrollHeight
  }

  showStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
