import { Controller } from "@hotwired/stimulus"

// Below 900px the sidebar turns into a drawer behind a menu button.
//
// The drawer is switched on here (.has-drawer) rather than in CSS alone: without JS the sidebar
// stays a plain block above the content, so a narrow screen never ends up with navigation hidden
// behind a button that does nothing.
export default class extends Controller {
  static targets = ["panel", "button", "scrim"]

  connect() {
    this.open = false
    this.sync()

    // Pages refresh by morphing: the shell element survives but its attributes are reset from the
    // server HTML (no .has-drawer, aria-expanded="false"), and nothing reconnects. Re-apply.
    this.onMorph = () => this.sync()
    document.addEventListener("turbo:morph", this.onMorph)
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.onMorph)
  }

  toggle() {
    this.open ? this.close() : this.show()
  }

  show() {
    this.open = true
    this.sync()
    this.panelTarget.querySelector("a, button")?.focus()
  }

  close() {
    if (!this.open) return

    this.open = false
    this.sync()
    this.buttonTarget.focus()
  }

  sync() {
    this.element.classList.add("has-drawer")
    this.element.classList.toggle("is-drawer-open", this.open)
    this.buttonTarget.setAttribute("aria-expanded", String(this.open))
    this.scrimTarget.hidden = !this.open
  }
}
