import { Controller } from "@hotwired/stimulus"

// 上报 token 的脚本只在生成后那一次出现，所以用模态框端到脸前，而不是让人
// 自己在页面里找。下载按钮把两段脚本拼成一个 .txt，内容直接读 DOM 里的
// <pre>，不另存一份——两处文本漂移的话，下载到的那份会是错的。
export default class extends Controller {
  static targets = ["script"]
  static values = { filename: String }

  connect() {
    if (typeof this.element.showModal !== "function") return

    this.element.showModal()
    // 内容高过 max-height 时，浏览器给焦点做的滚动会把标题与警示条顶出可视区。
    // 最要紧的那句话必须是打开时第一眼看到的东西。
    this.element.scrollTop = 0
    // showModal 挡住了交互，但遮罩下面的页面仍然能被滚轮滚动。
    document.documentElement.classList.add("scroll-locked")
  }

  disconnect() {
    document.documentElement.classList.remove("scroll-locked")
  }

  close() {
    this.element.close()
  }

  // 关掉之后不留在 DOM 里：脚本含明文 token，没有理由让它继续躺在页面上。
  // remove() 会触发 disconnect()，滚动锁在那里解开。
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
