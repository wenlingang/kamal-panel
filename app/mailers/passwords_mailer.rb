class PasswordsMailer < ApplicationMailer
  # Render in the [recipient's] language, not the I18n.locale at the moment of sending.
  def reset(user)
    @user = user

    I18n.with_locale(user.locale.presence || I18n.default_locale) do
      mail subject: t("passwords_mailer.reset.subject"), to: user.email_address
    end
  end
end
