import { Controller } from "@hotwired/stimulus"

// Closes a <details> popover on a click outside it or on Esc. Opening and closing by its own
// summary stays native, so the menu still works without JS.
export default class extends Controller {
  outside(event) {
    if (this.element.open && !this.element.contains(event.target)) this.element.open = false
  }

  close() {
    if (!this.element.open) return

    this.element.open = false
    this.element.querySelector("summary")?.focus()
  }
}
