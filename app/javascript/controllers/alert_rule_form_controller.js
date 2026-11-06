import { Controller } from "@hotwired/stimulus"

// Shows only the fields that apply to the chosen condition (log settings for a log rule, "for how
// long" for the ones that wait). Without JS every field stays visible, each with a hint saying which
// conditions use it, and the server ignores the ones that don't apply.
export default class extends Controller {
  static targets = ["condition", "section"]

  connect() {
    this.toggle()
  }

  toggle() {
    const condition = this.conditionTarget.value
    this.sectionTargets.forEach((section) => {
      section.hidden = !section.dataset.conditions.split(" ").includes(condition)
    })
  }
}
