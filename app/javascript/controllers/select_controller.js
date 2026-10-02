import { Controller } from "@hotwired/stimulus"

// A shadcn-style trigger + menu panel. The native select is visually hidden but still carries the value in the form.
export default class extends Controller {
  connect() {
    this.select = this.element
    this.mount()

    this.onDocumentPointerdown = (e) => {
      if (this.root && !this.root.contains(e.target)) this.close()
    }
    document.addEventListener("pointerdown", this.onDocumentPointerdown)

    // morph deletes this injected container (it is not in the server HTML) while the native select survives,
    // so Stimulus will not reconnect — put it back ourselves.
    this.onMorph = () => { if (!this.root?.isConnected) this.mount() }
    document.addEventListener("turbo:morph", this.onMorph)
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.onDocumentPointerdown)
    document.removeEventListener("turbo:morph", this.onMorph)
    this.root?.remove()
  }

  mount() {
    this.root?.remove()
    this.open = false
    this.activeIndex = -1

    this.build()
    this.select.classList.add("visually-hidden")
    this.select.setAttribute("tabindex", "-1")
    this.select.setAttribute("aria-hidden", "true")
  }

  get options() {
    return Array.from(this.select.options)
  }

  build() {
    this.root = document.createElement("div")
    this.root.className = "sel"

    this.trigger = document.createElement("button")
    this.trigger.type = "button"
    this.trigger.className = "sel-trigger"
    this.trigger.setAttribute("role", "combobox")
    this.trigger.setAttribute("aria-expanded", "false")
    this.trigger.setAttribute("aria-haspopup", "listbox")

    const label = this.select.labels?.[0]
    if (label) this.trigger.setAttribute("aria-label", label.textContent.trim())

    this.valueEl = document.createElement("span")
    this.valueEl.className = "sel-value"
    this.trigger.append(this.valueEl, this.chevron())

    this.list = document.createElement("div")
    this.list.className = "sel-list"
    this.list.setAttribute("role", "listbox")
    this.list.hidden = true

    this.items = this.options.map((option, i) => {
      const item = document.createElement("div")
      item.className = "sel-item"
      item.id = `${this.uid()}-opt-${i}`
      item.setAttribute("role", "option")
      item.dataset.index = i

      const text = document.createElement("span")
      text.textContent = option.text
      item.append(text, this.checkMark())

      // preventDefault on mousedown is the key here: a menu item is a div, and pressing it makes the
      // trigger lose focus, so the blur handler below closes the menu in rAF — while click
      // only arrives on mouseup, by which time the target is already hidden, click never fires, and the selection is lost.
      // The longer the press, the more surely it is hit (automated clicks finish within one frame and cannot reveal it).
      item.addEventListener("mousedown", (e) => e.preventDefault())
      item.addEventListener("click", () => this.choose(i))
      item.addEventListener("pointermove", () => this.highlight(i))
      this.list.append(item)
      return item
    })

    this.list.setAttribute("id", `${this.uid()}-list`)
    this.trigger.setAttribute("aria-controls", this.list.id)

    this.root.append(this.trigger, this.list)
    this.select.after(this.root)

    this.trigger.addEventListener("click", () => this.toggle())
    this.trigger.addEventListener("keydown", (e) => this.onKeydown(e))
    this.trigger.addEventListener("blur", () => {
      if (this.open) requestAnimationFrame(() => {
        if (!this.root.contains(document.activeElement)) this.close()
      })
    })

    this.sync()
  }

  uid() {
    this._uid ||= `sel-${Math.random().toString(36).slice(2, 8)}`
    return this._uid
  }

  chevron() {
    return this.svg("m6 9 6 6 6-6", "sel-chevron")
  }

  checkMark() {
    return this.svg("M20 6 9 17l-5-5", "sel-check")
  }

  svg(d, klass) {
    const ns = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("fill", "none")
    svg.setAttribute("stroke", "currentColor")
    svg.setAttribute("stroke-width", "1.5")
    svg.setAttribute("stroke-linecap", "round")
    svg.setAttribute("stroke-linejoin", "round")
    svg.setAttribute("aria-hidden", "true")
    svg.setAttribute("class", `icon ${klass}`)
    const path = document.createElementNS(ns, "path")
    path.setAttribute("d", d)
    svg.append(path)
    return svg
  }

  sync() {
    const i = this.select.selectedIndex
    this.valueEl.textContent = i >= 0 ? this.options[i].text : ""
    this.items.forEach((item, n) => {
      const selected = n === i
      item.setAttribute("aria-selected", selected ? "true" : "false")
      item.classList.toggle("is-selected", selected)
    })
  }

  toggle() {
    this.open ? this.close() : this.show()
  }

  show() {
    if (this.open) return
    this.open = true
    this.list.hidden = false
    this.trigger.setAttribute("aria-expanded", "true")
    this.root.classList.add("is-open")
    this.placeList()
    this.highlight(this.select.selectedIndex >= 0 ? this.select.selectedIndex : 0)
    this.items[this.activeIndex]?.scrollIntoView({ block: "nearest" })
  }

  close() {
    if (!this.open) return
    this.open = false
    this.list.hidden = true
    this.trigger.setAttribute("aria-expanded", "false")
    this.trigger.removeAttribute("aria-activedescendant")
    this.root.classList.remove("is-open", "drops-up")
    this.items[this.activeIndex]?.classList.remove("is-active")
    this.activeIndex = -1
  }

  placeList() {
    const space = window.innerHeight - this.trigger.getBoundingClientRect().bottom
    this.root.classList.toggle("drops-up", space < 240)
  }

  highlight(i) {
    if (i < 0 || i >= this.items.length) return
    this.items[this.activeIndex]?.classList.remove("is-active")
    this.activeIndex = i
    const item = this.items[i]
    item.classList.add("is-active")
    this.trigger.setAttribute("aria-activedescendant", item.id)
  }

  choose(i) {
    this.select.selectedIndex = i
    this.sync()
    this.close()
    this.trigger.focus()
    this.select.dispatchEvent(new Event("input", { bubbles: true }))
    this.select.dispatchEvent(new Event("change", { bubbles: true }))
  }

  onKeydown(e) {
    const last = this.items.length - 1

    if (!this.open) {
      if (["Enter", " ", "ArrowDown", "ArrowUp"].includes(e.key)) {
        e.preventDefault()
        this.show()
        if (e.key === "ArrowUp") this.highlight(last)
      }
      return
    }

    switch (e.key) {
      case "Escape":
        e.preventDefault()
        this.close()
        break
      case "Enter":
      case " ":
        e.preventDefault()
        this.choose(this.activeIndex)
        break
      case "ArrowDown":
        e.preventDefault()
        this.highlight(Math.min(this.activeIndex + 1, last))
        this.items[this.activeIndex].scrollIntoView({ block: "nearest" })
        break
      case "ArrowUp":
        e.preventDefault()
        this.highlight(Math.max(this.activeIndex - 1, 0))
        this.items[this.activeIndex].scrollIntoView({ block: "nearest" })
        break
      case "Home":
        e.preventDefault()
        this.highlight(0)
        break
      case "End":
        e.preventDefault()
        this.highlight(last)
        break
      case "Tab":
        this.close()
        break
      default:
        if (e.key.length === 1) this.typeahead(e.key)
    }
  }

  typeahead(char) {
    clearTimeout(this._typeTimer)
    this._typed = (this._typed || "") + char.toLowerCase()
    this._typeTimer = setTimeout(() => (this._typed = ""), 800)

    const i = this.items.findIndex((item) =>
      item.textContent.trim().toLowerCase().startsWith(this._typed))
    if (i >= 0) {
      this.highlight(i)
      this.items[i].scrollIntoView({ block: "nearest" })
    }
  }
}
