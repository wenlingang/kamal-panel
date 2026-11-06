module Notifiers
  # Slack incoming webhook: {text}, plus a section block so the title stands out. Slack answers
  # a plain "ok" on success and a 4xx with a reason ("invalid_token", "no_text") otherwise.
  class Slack < Base
    private
      def perform(message)
        response, _json = post_json(payload(message))

        response.is_a?(Net::HTTPSuccess) ? Result.success : http_failure(response)
      end

      def payload(message)
        text = "*#{escape(message.title)}*\n#{escape(message.body)}"
        {
          text: "#{message.title}\n#{message.body}",
          blocks: [ { type: "section", text: { type: "mrkdwn", text: } } ]
        }
      end

      # Slack's three control characters in mrkdwn; anything else (app names, log lines) is shown as is.
      def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end
