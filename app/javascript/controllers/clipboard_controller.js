import { Controller } from "@hotwired/stimulus"

// A copy-to-clipboard button: copies textValue, then shows the check icon for a moment.
// navigator.clipboard only exists in a secure context (https or localhost); a panel served over
// plain http falls back to a hidden textarea + execCommand("copy").
export default class extends Controller {
  static values = { text: String, copiedLabel: String }

  async copy(event) {
    event.preventDefault()

    const ok = await this.write(this.textValue)
    if (ok) this.flash()
  }

  async write(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text)
        return true
      }
    } catch (_) {
      // Permission denied or similar: try the fallback below.
    }

    const area = document.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.style.position = "fixed"
    area.style.opacity = "0"
    document.body.appendChild(area)
    area.select()
    let ok = false
    try {
      ok = document.execCommand("copy")
    } catch (_) {
      ok = false
    }
    area.remove()
    return ok
  }

  flash() {
    const label = this.element.getAttribute("aria-label")
    this.element.classList.add("is-copied")
    if (this.copiedLabelValue) {
      this.element.setAttribute("aria-label", this.copiedLabelValue)
      this.element.title = this.copiedLabelValue
    }

    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.element.classList.remove("is-copied")
      this.element.setAttribute("aria-label", label)
      this.element.title = label
    }, 1500)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
