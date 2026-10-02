import { Controller } from "@hotwired/stimulus"

// Submit on selection, and hide the submit button that serves as the fallback.
//
// Hiding the button must be done by JS itself and cannot be hard-coded in CSS: CSS cannot know whether JS
// has actually loaded. Without JS (or if JS is broken) the button stays and the form still works — this is the same principle as
// the :has() expansion for the password setup method: after degrading, the feature is still there, just less convenient.
export default class extends Controller {
  static targets = ["fallback"]

  // Use targetConnected rather than iterating fallbackTargets in connect(): the controller is attached to
  // the form, and connect() may fire before the browser has finished parsing the form's children, when
  // fallbackTargets is empty and the button could never be hidden (this is not a hypothesis; it was found by testing).
  fallbackTargetConnected(button) {
    button.hidden = true
  }

  submit() {
    this.element.requestSubmit()
  }
}
