// 把 Turbo 的 data-turbo-confirm 从原生 confirm() 换成这套设计里的对话框。
//
// 文案用 "标题\n正文" 的形式传：第一行做标题，其余做正文。
// Turbo 只要一个返回 Promise<boolean> 的函数，所以不需要任何 Stimulus 控制器。
import { Turbo } from "@hotwired/turbo-rails"

const CANCEL = document.documentElement.lang === "en" ? "Cancel" : "取消"
const OK = document.documentElement.lang === "en" ? "Confirm" : "确认"

function build(message, danger) {
  const [title, ...rest] = message.split("\n")

  const dialog = document.createElement("dialog")
  dialog.className = "confirm-dialog"

  const head = document.createElement("h2")
  head.textContent = title
  dialog.append(head)

  if (rest.length) {
    const body = document.createElement("p")
    body.textContent = rest.join("\n")
    dialog.append(body)
  }

  const actions = document.createElement("div")
  actions.className = "confirm-actions"

  const cancel = document.createElement("button")
  cancel.type = "button"
  cancel.textContent = CANCEL
  cancel.value = "cancel"

  const ok = document.createElement("button")
  ok.type = "button"
  // 红色只给真正破坏性的动作。启用一个应用不是破坏性的，红按钮会稀释这个信号。
  if (danger) ok.className = "btn-danger"
  ok.textContent = OK
  ok.value = "ok"

  actions.append(cancel, ok)
  dialog.append(actions)

  return { dialog, cancel, ok }
}

Turbo.setConfirmMethod((message, element, submitter) => {
  const danger = (submitter || element)?.closest("[data-confirm-danger]") != null
  const { dialog, cancel, ok } = build(message, danger)
  document.body.append(dialog)

  return new Promise((resolve) => {
    const close = (answer) => {
      dialog.close()
      dialog.remove()
      resolve(answer)
    }

    cancel.addEventListener("click", () => close(false))
    ok.addEventListener("click", () => close(true))
    // Esc 关闭走的是 dialog 自己的 cancel 事件
    dialog.addEventListener("cancel", (e) => { e.preventDefault(); close(false) })
    // 点遮罩关闭：::backdrop 收不到事件，落到 dialog 自己身上的点击就是点在遮罩上
    dialog.addEventListener("click", (e) => { if (e.target === dialog) close(false) })

    dialog.showModal()
    cancel.focus()
  })
})
