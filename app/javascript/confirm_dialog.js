// Swap Turbo's data-turbo-confirm from the native confirm() to the dialog from this design.
//
// The copy is passed as "title\nbody": the first line is the title and the rest is the body.
// Turbo only needs a function that returns Promise<boolean>, so no Stimulus controller is needed.
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
  // Red is only for truly destructive actions. Enabling an app is not destructive, and a red button would dilute that signal.
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
    // Esc closes via the dialog's own cancel event
    dialog.addEventListener("cancel", (e) => { e.preventDefault(); close(false) })
    // Click on the backdrop closes: ::backdrop receives no events, so a click landing on the dialog itself is a click on the backdrop
    dialog.addEventListener("click", (e) => { if (e.target === dialog) close(false) })

    dialog.showModal()
    cancel.focus()
  })
})
