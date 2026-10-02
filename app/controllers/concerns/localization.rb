# Decides the UI language once per request.
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

    # Three levels, highest to lowest: the user's own preference -> browser -> default.
    # Logged-out pages (login page, set-password page) can only ask at the second level.
    def resolved_locale
      Current.user&.locale.presence&.to_sym ||
        Localization.match_accept_language(request.env["HTTP_ACCEPT_LANGUAGE"]) ||
        I18n.default_locale
    end
end
