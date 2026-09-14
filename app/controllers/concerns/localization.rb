# 每个请求决定一次界面语言。
#
# 用 around_action 而不是 before_action：I18n.locale 是线程级全局状态，
# 请求结束必须还原，否则同一个线程服务下一个请求时会带着上一个用户的语言。
# I18n.with_locale 自带这个还原，包括抛异常那条路径。
module Localization
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
  end

  # 只做粗匹配：取头部里第一个认得出的语言标签，zh 开头的一律算 zh-CN，
  # 其余看是否恰好在 available_locales 里。不实现 RFC 4647 的权重协商
  # ——两种语言不值得，而一个只有两个分支的判断在测试里穷尽得完。
  #
  # 做成模块函数而不是控制器的私有方法，是为了能直接喂字符串单测：埋在控制器
  # 里的话只能靠"渲染一个页面看它变没变"来间接验证，而 around_action 会在
  # 请求结束时还原 I18n.locale，那种间接验证立不住。
  def self.match_accept_language(header)
    return nil if header.blank?

    available = I18n.available_locales.map(&:to_s)

    header.scan(/[A-Za-z-]{2,}/).each do |tag|
      return :"zh-CN" if tag.downcase.start_with?("zh")
      return tag.to_sym if available.include?(tag)
    end

    nil
  end

  private
    def switch_locale(&) = I18n.with_locale(resolved_locale, &)

    # 三级，从高到低：用户自己的偏好 → 浏览器 → 默认。
    # 未登录页面（登录页、设置密码页）只有第二级可问。
    def resolved_locale
      Current.user&.locale.presence&.to_sym ||
        Localization.match_accept_language(request.env["HTTP_ACCEPT_LANGUAGE"]) ||
        I18n.default_locale
    end
end
