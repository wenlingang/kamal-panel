import { Controller } from "@hotwired/stimulus"

// Type-ahead suggestions under a text field, from a fixed list (e.g. the app names on the overview):
// typing shows the names containing what was typed, arrows move through them, Enter or a click puts
// the name in the field and fires `change`, which the surrounding auto-submit form submits on.
// Without a highlighted suggestion, Enter behaves as usual.
//
//   <span data-controller="suggest" data-suggest-items-value='["blog","shop"]'>
//     <input data-suggest-target="input" data-action="input->suggest#update keydown->suggest#keydown
//                                                      blur->suggest#close focus->suggest#update">
//   </span>
const LIMIT = 8

export default class extends Controller {
  static targets = [ "input" ]
  static values = { items: Array }

  connect() {
    this.list = document.createElement("div")
    this.list.className = "sel-list suggest-list"
    this.list.setAttribute("role", "listbox")
    this.list.id = `suggest-${Math.random().toString(36).slice(2, 8)}`
    this.list.hidden = true
    this.matches = []
    this.active = -1
    this.attach()

    // The overview refreshes by morphing, which removes this injected list (it is not in the server
    // HTML) and resets the input's attributes, while the elements survive so Stimulus won't
    // reconnect: put both back ourselves.
    this.onMorph = () => this.attach()
    document.addEventListener("turbo:morph", this.onMorph)
  }

  attach() {
    if (!this.list.isConnected) this.element.append(this.list)
    this.inputTarget.setAttribute("role", "combobox")
    this.inputTarget.setAttribute("aria-autocomplete", "list")
    this.inputTarget.setAttribute("aria-controls", this.list.id)
    this.inputTarget.setAttribute("aria-expanded", this.list.hidden ? "false" : "true")
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.onMorph)
    this.list?.remove()
  }

  update() {
    const needle = this.inputTarget.value.trim().toLowerCase()
    this.matches = needle === "" ? [] :
      this.itemsValue.filter((name) => name.toLowerCase().includes(needle))
                     // Names that start with what was typed first, then the rest, each alphabetically.
                     .sort((a, b) => (b.toLowerCase().startsWith(needle) - a.toLowerCase().startsWith(needle)) || a.localeCompare(b))
                     .slice(0, LIMIT)

    // Exactly what is already typed is not a suggestion.
    if (this.matches.length === 1 && this.matches[0].toLowerCase() === needle) this.matches = []
    this.render()
  }

  render() {
    this.active = -1
    this.list.replaceChildren(...this.matches.map((name, i) => {
      const item = document.createElement("div")
      item.className = "sel-item"
      item.id = `${this.list.id}-${i}`
      item.setAttribute("role", "option")
      item.textContent = name
      // mousedown would blur the input first and close the list before the click lands.
      item.addEventListener("mousedown", (e) => e.preventDefault())
      item.addEventListener("click", () => this.pick(i))
      item.addEventListener("pointermove", () => this.highlight(i))
      return item
    }))
    const open = this.matches.length > 0
    this.list.hidden = !open
    this.inputTarget.setAttribute("aria-expanded", open ? "true" : "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
  }

  keydown(e) {
    if (this.list.hidden) return

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        this.highlight(Math.min(this.active + 1, this.matches.length - 1))
        break
      case "ArrowUp":
        e.preventDefault()
        this.highlight(Math.max(this.active - 1, 0))
        break
      case "Enter":
        if (this.active >= 0) {
          e.preventDefault()
          this.pick(this.active)
        }
        break
      case "Escape":
        e.preventDefault()
        this.close()
        break
    }
  }

  highlight(i) {
    this.list.children[this.active]?.classList.remove("is-active")
    this.active = i
    const item = this.list.children[i]
    if (!item) return
    item.classList.add("is-active")
    item.scrollIntoView({ block: "nearest" })
    this.inputTarget.setAttribute("aria-activedescendant", item.id)
  }

  pick(i) {
    this.inputTarget.value = this.matches[i]
    this.close()
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  close() {
    this.matches = []
    this.render()
  }
}
