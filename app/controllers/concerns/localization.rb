# 每个请求决定一次界面语言。
module Localization
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
  end

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
