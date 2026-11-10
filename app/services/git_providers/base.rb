require "json"

module GitProviders
  # Shared plumbing: authenticated JSON GETs with the panel's timeout, one error type, and a short
  # cache. Subclasses only know their provider's paths and payload shapes.
  #
  # Interface (every provider): current_user, default_branch, commits(branch:, limit:), tags(limit:),
  # commit(sha), commit_for_tag(tag), ci_status(sha), compare(from, to), and the URL builders
  # commit_url / tag_url / compare_url, which never touch the network (deploy history and the
  # overview render links from them).
  class Base
    # Long enough to absorb a page reload or a tab switch, short enough that a pipeline finishing
    # shows up within a minute.
    CACHE_TTL = 60.seconds

    # The token is decrypted here, on the caller's thread: provider calls may run on worker
    # threads (OutboundHttp.parallel_map).
    def initialize(connection, repository)
      @connection = connection
      @repository = repository
      @token = connection.token
    end

    attr_reader :connection, :repository

    def commit_for_tag(tag) = tag.commit || commit(tag.sha)

    private
      attr_reader :token

      def repo_web_url = "#{connection.web_url}/#{repository}"

      def segment(value) = ERB::Util.url_encode(value.to_s)

      # The token's own id is not in the key: rotating it bumps updated_at, which is.
      def cached(*parts, expires_in: CACHE_TTL, &)
        key = [ "git", connection.id, connection.updated_at.to_i, repository, *parts ].join("/")
        Rails.cache.fetch(key, expires_in:, &)
      end

      def get_json(path, params = {})
        url = "#{connection.api_url}#{path}"
        url += "?#{params.compact.to_query}" if params.compact.any?

        response = OutboundHttp.request(:get, url, headers: auth_headers.merge("Accept" => accept_header))
        handle(response)
      rescue OutboundHttp::Error => e
        raise Error.new(:unreachable, detail: e.message)
      end

      def handle(response)
        status = response.code.to_i
        case status
        when 200..299
          JSON.parse(response.body.to_s)
        when 401
          raise Error.new(:unauthorized)
        when 403, 429
          raise Error.new(rate_limited?(response, status) ? :rate_limited : :forbidden)
        when 404
          raise Error.new(:not_found, repository: repository.to_s)
        else
          raise Error.new(:http_status, status: status)
        end
      rescue JSON::ParserError
        raise Error.new(:bad_response)
      end

      def rate_limited?(response, status)
        status == 429 || response["x-ratelimit-remaining"] == "0" || response["ratelimit-remaining"] == "0"
      end

      def accept_header = "application/json"

      def parse_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
  end
end
