require "base64"
require "openssl"

module Notifiers
  # Feishu / Lark custom bot. A plain text message (title, body, link): it renders everywhere,
  # including the mobile lock screen, which an interactive card doesn't.
  #
  # With the bot's "signature verification" on, the secret signs a timestamp (Feishu docs):
  #   sign = Base64(HMAC-SHA256(key: "#{timestamp}\n#{secret}", data: ""))
  # Feishu answers HTTP 200 even for a refused message; the verdict is the JSON code (0 = sent).
  class Feishu < Base
    def self.sign(timestamp, secret)
      Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", "#{timestamp}\n#{secret}", ""))
    end

    private
      def perform(message)
        response, json = post_json(payload(message))
        return http_failure(response) unless response.is_a?(Net::HTTPSuccess)

        # Newer bots answer {"code":0,"msg":"success"}; older ones {"StatusCode":0,...}.
        code = json.is_a?(Hash) ? (json["code"] || json["StatusCode"]) : nil
        return Result.success if code.nil? || code.to_i.zero?

        Result.failure("Feishu #{code}: #{json['msg'] || json['StatusMessage']}")
      end

      def payload(message)
        body = { msg_type: "text", content: { text: "#{message.title}\n#{message.body}" } }
        return body if channel.secret.blank?

        timestamp = Time.current.to_i.to_s
        body.merge(timestamp:, sign: self.class.sign(timestamp, channel.secret))
      end
  end
end
