require "net/smtp"


module Notifiers
  # Through ActionMailer, delivered right away (the caller is already a background job, or the
  # "send test" button, which wants the verdict now). Needs SMTP configured; see README.
  class Email < Base
    # What a misconfigured or unreachable mail server raises.
    MAIL_ERRORS = [
      Net::SMTPAuthenticationError, Net::SMTPServerBusy, Net::SMTPSyntaxError, Net::SMTPFatalError,
      Net::SMTPUnknownError, Net::OpenTimeout, Net::ReadTimeout, IOError, SocketError,
      SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
    ].freeze

    private
      def perform(message)
        AlertMailer.notification(channel.recipients, message).deliver_now
        Result.success
      rescue *MAIL_ERRORS => e
        Result.failure("#{e.class}: #{e.message}")
      end
  end
end
