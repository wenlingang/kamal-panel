require "json"

module Notifiers
  class Base
    def initialize(channel)
      @channel = channel
    end

    def deliver(message)
      perform(message)
    rescue OutboundHttp::Error => e
      Result.failure(e.message)
    end

    private
      attr_reader :channel

      def perform(message) = raise(NotImplementedError)

      # The block, if given, gets the serialized body and returns extra headers (a signature over
      # the exact bytes sent).
      def post_json(payload)
        body = payload.to_json
        headers = { "Content-Type" => "application/json" }.merge(block_given? ? yield(body) : {})
        response = OutboundHttp.request(:post, channel.target, body:, headers:)
        [ response, parse(response.body) ]
      end

      def parse(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end

      # Only the status code, never the response body: the target is an admin-entered URL that may
      # well point inside the network (internal webhook receivers are a legitimate use), and echoing
      # whatever answered there into the UI and the channel's last_error would turn "send test" into
      # a way to read internal pages.
      def http_failure(response)
        Result.failure("HTTP #{response.code}")
      end
  end
end
