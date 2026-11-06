require "base64"
require "json"

# Is the image for a version already in the registry? (spec 6, "image ready")
#
# One Docker Registry v2 manifest HEAD per version. CI pushes the image, the panel only pulls it
# (`kamal deploy --skip-push`), so a missing image means the deploy would fail at the pull step.
# The answer is advisory: :unknown (no credentials, registry down, unexpected answer) never blocks
# a deploy, it only adds a warning.
class RegistryProbe
  DOCKER_HUB_ALIASES = [ nil, "", "docker.io", "index.docker.io", "registry-1.docker.io" ].freeze
  DOCKER_HUB_HOST = "registry-1.docker.io".freeze

  # Ask for every manifest kind a multi-arch or single-arch push can produce; a registry answers
  # 404 for a tag whose only manifest kind wasn't listed.
  MANIFEST_TYPES = [
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json"
  ].join(", ").freeze

  CACHE_TTL = 60.seconds

  # Everything needed is read here, on the caller's thread: #status runs on worker threads
  # (OutboundHttp.parallel_map), which must not touch the database.
  def initialize(managed_app)
    config = managed_app.parsed_config
    @host, @image = registry_location(config.registry_server, config.image)
    @username = config.registry_username
    # The credential is only sent to the registry it was registered for. deploy.yml is editable by
    # app members, while the credential is assigned by an admin: without this pin, pointing
    # registry.server at another host would hand that host the password. An unpinned or mismatched
    # credential probes anonymously, which at worst turns the answer into :unknown (advisory only).
    credential = managed_app.registry_credential
    @password = credential.value if credential && pinned_to_host?(credential.server)
    @credential_stamp = managed_app.registry_credential&.updated_at.to_i
  end

  attr_reader :host, :image

  # => :present | :missing | :unknown
  def status(version)
    return :unknown if image.blank? || version.blank?

    key = [ "registry_probe", host, image, version, credential_stamp ].join("/")
    cached = Rails.cache.read(key)
    return cached if cached

    result = probe(version.to_s)
    # Only definite answers are worth keeping; an :unknown is retried on the next page view.
    Rails.cache.write(key, result, expires_in: CACHE_TTL) unless result == :unknown
    result
  rescue OutboundHttp::Error, JSON::ParserError, ArgumentError
    :unknown
  end

  private
    attr_reader :username, :password, :credential_stamp

    def registry_location(server, image)
      return [ server, image ] unless DOCKER_HUB_ALIASES.include?(server)

      # Docker Hub's official images live under library/ ("postgres" is "library/postgres").
      [ DOCKER_HUB_HOST, image.to_s.include?("/") ? image : "library/#{image}" ]
    end

    def pinned_to_host?(server)
      return false if server.blank?

      registry_location(server.to_s.strip.downcase.delete_prefix("https://").chomp("/"), image).first == host.to_s.downcase
    end

    def manifest_url(version) = "https://#{host}/v2/#{image}/manifests/#{ERB::Util.url_encode(version)}"

    def probe(version)
      response = head(version)
      response = authenticated_retry(response, version) if response.code.to_i == 401

      case response.code.to_i
      when 200 then :present
      when 404 then :missing
      else :unknown
      end
    end

    def head(version, authorization = nil)
      headers = { "Accept" => MANIFEST_TYPES }
      headers["Authorization"] = authorization if authorization
      OutboundHttp.request(:head, manifest_url(version), headers:)
    end

    # The registry says how it wants to be authenticated in WWW-Authenticate: Basic (send the
    # credentials straight away) or Bearer (fetch a token from its auth service first, the
    # Docker Hub / GHCR / Harbor way).
    def authenticated_retry(response, version)
      challenge = response["www-authenticate"].to_s
      scheme = challenge[/\A\s*(\w+)/, 1].to_s.downcase

      case scheme
      when "bearer"
        token = bearer_token(challenge_params(challenge))
        token ? head(version, "Bearer #{token}") : response
      when "basic"
        basic_credentials ? head(version, "Basic #{basic_credentials}") : response
      else
        response
      end
    end

    def challenge_params(challenge)
      challenge.scan(/(\w+)="([^"]*)"/).to_h
    end

    def bearer_token(params)
      realm = params["realm"].to_s
      # Credentials go into this request, so never over plain http.
      return nil unless realm.match?(%r{\Ahttps://}i)

      query = params.slice("service", "scope").to_query
      headers = {}
      headers["Authorization"] = "Basic #{basic_credentials}" if basic_credentials

      response = OutboundHttp.request(:get, query.empty? ? realm : "#{realm}?#{query}", headers:)
      return nil unless response.code.to_i == 200

      body = JSON.parse(response.body.to_s)
      body["token"].presence || body["access_token"].presence
    end

    # A registry credential holds only the password; the username comes from deploy.yml, where it
    # can be read only when it is a literal (a secret reference is resolved at deploy time). GHCR
    # and most token-based registries accept any username with a token, so fall back to a fixed
    # one rather than giving up.
    def basic_credentials
      return nil if password.blank?

      @basic_credentials ||= Base64.strict_encode64("#{username.presence || 'kamal-panel'}:#{password}")
    end
end
