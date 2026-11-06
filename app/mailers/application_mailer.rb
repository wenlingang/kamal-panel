class ApplicationMailer < ActionMailer::Base
  # The sender address the mail server accepts for the panel (password resets, alert emails).
  default from: -> { ENV.fetch("PANEL_MAIL_FROM", "kamal-panel@example.com") }
  layout "mailer"
end
