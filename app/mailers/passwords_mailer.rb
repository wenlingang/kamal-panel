class PasswordsMailer < ApplicationMailer
  # 按【收件人】的语言渲染，不是按发信那一刻的 I18n.locale。
  def reset(user)
    @user = user

    I18n.with_locale(user.locale.presence || I18n.default_locale) do
      mail subject: t("passwords_mailer.reset.subject"), to: user.email_address
    end
  end
end
