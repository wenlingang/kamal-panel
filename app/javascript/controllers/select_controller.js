import { Controller } from "@hotwired/stimulus"

// A shadcn-style trigger + menu panel. The native select is visually hidden but still carries the value in the form.
//
// A long list (SEARCH_MIN options or more, e.g. the app pickers once there are many apps) gets a filter box at the
// top of the menu: typing narrows the items by substring, arrows move through what is left, Enter picks.
// data-searchable="true" / "false" on the select forces it on or off.
const SEARCH_MIN = 8

const TEXT = {
  zh: { search: "搜索…", empty: "没有匹配项" },
  en: { search: "Search…", empty: "No matches" }
}

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

  get searchable() {
    const forced = this.select.dataset.searchable
    if (forced === "true") return true
    if (forced === "false") return false
    return this.options.length >= SEARCH_MIN
  }

  get text() {
    return document.documentElement.lang.startsWith("zh") ? TEXT.zh : TEXT.en
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
    if (this.searchable) this.buildSearch()

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

  // The filter box sits at the top of the menu, sticky while the items scroll under it; the "no matches"
  // row goes at the bottom.
  buildSearch() {
    const box = document.createElement("div")
    box.className = "sel-search"
    this.search = document.createElement("input")
    this.search.type = "text"
    this.search.autocomplete = "off"
    this.search.spellcheck = false
    this.search.placeholder = this.text.search
    this.search.setAttribute("aria-label", this.text.search)
    this.search.setAttribute("aria-controls", this.list.id)
    box.append(this.search)
    this.list.prepend(box)

    this.emptyEl = document.createElement("div")
    this.emptyEl.className = "sel-empty"
    this.emptyEl.textContent = this.text.empty
    this.emptyEl.hidden = true
    this.list.append(this.emptyEl)

    this.search.addEventListener("input", () => this.filter(this.search.value))
    this.search.addEventListener("keydown", (e) => this.onSearchKeydown(e))
    this.search.addEventListener("blur", () => {
      requestAnimationFrame(() => {
        if (this.open && !this.root.contains(document.activeElement)) this.close()
      })
    })
  }

  // Indices of the items currently shown (all of them unless a filter is typed).
  get visible() {
    return this.items.flatMap((item, i) => (item.hidden ? [] : [ i ]))
  }

  filter(query) {
    const needle = query.trim().toLowerCase()
    this.items.forEach((item) => {
      item.hidden = needle !== "" && !item.textContent.toLowerCase().includes(needle)
    })
    const visible = this.visible
    if (this.emptyEl) this.emptyEl.hidden = visible.length > 0
    if (!visible.includes(this.activeIndex)) {
      this.items[this.activeIndex]?.classList.remove("is-active")
      this.activeIndex = -1
      if (visible.length) this.highlight(visible[0])
    }
  }

  // Move the highlight by step through the visible items, clamped at both ends.
  step(by) {
    const visible = this.visible
    if (!visible.length) return
    const at = visible.indexOf(this.activeIndex)
    const next = at < 0 ? (by > 0 ? 0 : visible.length - 1) : Math.min(Math.max(at + by, 0), visible.length - 1)
    this.highlight(visible[next])
    this.items[this.activeIndex].scrollIntoView({ block: "nearest" })
  }

  onSearchKeydown(e) {
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        this.step(1)
        break
      case "ArrowUp":
        e.preventDefault()
        this.step(-1)
        break
      case "Enter":
        // Never let Enter reach the form: it would submit with the old value.
        e.preventDefault()
        if (this.visible.includes(this.activeIndex)) this.choose(this.activeIndex)
        break
      case "Escape":
        e.preventDefault()
        this.close()
        this.trigger.focus()
        break
      case "Tab":
        this.close()
        break
    }
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
    if (this.search) {
      this.search.value = ""
      this.filter("")
    }
    this.highlight(this.select.selectedIndex >= 0 ? this.select.selectedIndex : 0)
    this.items[this.activeIndex]?.scrollIntoView({ block: "nearest" })
    this.search?.focus()
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
