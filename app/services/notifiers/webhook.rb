require "openssl"

module Notifiers
  # A generic JSON POST (Notifiers::Message#as_payload). With a secret, the body is signed so the
  # receiver can tell the panel from anyone else who learned the URL:
  #   X-Kamal-Panel-Signature: sha256=<hex HMAC-SHA256(secret, raw body)>
  class Webhook < Base
    SIGNATURE_HEADER = "X-Kamal-Panel-Signature"

    def self.signature(secret, body) = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"

    private
      def perform(message)
        response, _json = post_json(message.as_payload) do |body|
          channel.secret.present? ? { SIGNATURE_HEADER => self.class.signature(channel.secret, body) } : {}
        end

        response.is_a?(Net::HTTPSuccess) ? Result.success : http_failure(response)
      end
  end
end
