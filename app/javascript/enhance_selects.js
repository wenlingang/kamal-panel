// 全站每个单选 <select> 都换成自定义下拉，不靠各个视图自己记得加
// data-controller="select"——此前就是这样漏掉了新建应用、人员那几个。
//
// 多选与 size > 1 的列表框排除在外：select_controller 是单选 listbox，
// 接管它们会静默丢掉多选能力。
const ELIGIBLE = "select:not([multiple]):not([data-controller~='select'])"

function enhance() {
  document.querySelectorAll(ELIGIBLE).forEach((select) => {
    if (select.size > 1) return

    const existing = select.getAttribute("data-controller")
    select.setAttribute("data-controller", existing ? `${existing} select` : "select")
  })
}

// morph 刷新会换掉 DOM，frame-load 会带进新的 select，两者都要补一遍。
for (const event of [ "turbo:load", "turbo:morph", "turbo:frame-load" ]) {
  document.addEventListener(event, enhance)
}
