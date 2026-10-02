import { Controller } from "@hotwired/stimulus"

// The reporting token's script appears only that once after generation, so a modal puts it right in front of the user rather than making them
// look for it on the page. The download button joins the two scripts into one .txt, reading the content straight from the
// <pre> in the DOM without keeping a separate copy — if the two texts drifted apart, the downloaded one would be wrong.
export default class extends Controller {
  static targets = ["script"]
  static values = { filename: String }

  connect() {
    if (typeof this.element.showModal !== "function") return

    this.element.showModal()
    // When the content is taller than max-height, the scrolling the browser does for focus would push the title and warning bar out of view.
    // The most important sentence must be the first thing seen on opening.
    this.element.scrollTop = 0
    // showModal blocks interaction, but the page beneath the backdrop can still be scrolled with the wheel.
    document.documentElement.classList.add("scroll-locked")
  }

  disconnect() {
    document.documentElement.classList.remove("scroll-locked")
  }

  close() {
    this.element.close()
  }

  // Do not leave it in the DOM after closing: the script contains the plaintext token, and there is no reason to let it keep lying on the page.
  // remove() triggers disconnect(), where the scroll lock is released.
  discard() {
    this.element.remove()
  }

  download() {
    const body = this.scriptTargets
      .map((pre) => `# ${pre.dataset.path}\n${pre.textContent.trim()}\n`)
      .join("\n")

    const url = URL.createObjectURL(new Blob([ body ], { type: "text/plain;charset=utf-8" }))
    const link = document.createElement("a")
    link.href = url
    link.download = this.filenameValue
    link.click()
    URL.revokeObjectURL(url)
  }
}
