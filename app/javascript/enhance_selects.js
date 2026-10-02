// Replace every single-select <select> site-wide with the custom dropdown, rather than relying on each view to remember to add
// data-controller="select" — that is how the new-app and people ones were missed before.
//
// Multi-selects and listboxes with size > 1 are excluded: select_controller is a single-select listbox,
// and taking them over would silently drop the multi-select ability.
const ELIGIBLE = "select:not([multiple]):not([data-controller~='select'])"

function enhance() {
  document.querySelectorAll(ELIGIBLE).forEach((select) => {
    if (select.size > 1) return

    const existing = select.getAttribute("data-controller")
    select.setAttribute("data-controller", existing ? `${existing} select` : "select")
  })
}

// morph refreshes replace the DOM and frame-load brings in new selects; both need a pass.
for (const event of [ "turbo:load", "turbo:morph", "turbo:frame-load" ]) {
  document.addEventListener(event, enhance)
}
