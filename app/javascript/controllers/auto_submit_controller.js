import { Controller } from "@hotwired/stimulus"

// 选了就提交，并把那个作为退路的提交按钮藏起来。
//
// 藏按钮这件事必须由 JS 自己做，不能写死在 CSS 里：CSS 没法知道 JS 到底加载
// 上没有。没有 JS（或者 JS 挂了）的时候按钮留着，表单照样能用——这和密码设置
// 方式那个 :has() 展开是同一条原则：降级之后功能还在，只是不那么顺手。
export default class extends Controller {
  static targets = ["fallback"]

  // 用 targetConnected 而不是在 connect() 里遍历 fallbackTargets：控制器挂在
  // form 上，而 connect() 可能在浏览器还没解析完 form 的子节点时就触发，那时
  // fallbackTargets 是空的，按钮就永远藏不掉了（这不是假设，是测出来的）。
  fallbackTargetConnected(button) {
    button.hidden = true
  }

  submit() {
    this.element.requestSubmit()
  }
}
