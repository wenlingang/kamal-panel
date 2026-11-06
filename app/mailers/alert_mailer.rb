# Email channel of the alerting (spec 8). The message is already rendered in the default locale
# (Notifiers::Message); the mailer only lays it out.
class AlertMailer < ApplicationMailer
  def notification(recipients, message)
    @message = message

    I18n.with_locale(I18n.default_locale) do
      mail to: recipients, subject: message.title
    end
  end
end
