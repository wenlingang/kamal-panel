# A read-only API token for one GitHub / GitLab / Gitee instance (spec 6). Admin-managed like credentials:
# the token is encrypted, never rendered back, and only replaced as a whole.
class GitConnection < ApplicationRecord
  PROVIDERS = %w[github gitlab gitee].freeze

  DEFAULTS = {
    "github" => { api_url: "https://api.github.com", web_url: "https://github.com" },
    "gitlab" => { api_url: "https://gitlab.com/api/v4", web_url: "https://gitlab.com" },
    "gitee" => { api_url: "https://gitee.com/api/v5", web_url: "https://gitee.com" }
  }.freeze

  # Where the API lives under a self-hosted instance's own address (GitHub Enterprise Server,
  # self-managed GitLab, Gitee private deployments). Lets the admin fill in either URL.
  API_PATHS = { "github" => "/api/v3", "gitlab" => "/api/v4", "gitee" => "/api/v5" }.freeze

  encrypts :token

  # Deleting a connection that apps still point at would silently turn their deploy tab into
  # "manual entry only"; make the admin unhook those apps first.
  has_many :managed_apps, dependent: :restrict_with_error, inverse_of: :git_connection

  before_validation :apply_defaults

  validates :name, presence: true, uniqueness: true
  validates :provider, inclusion: { in: PROVIDERS }
  validates :token, presence: true
  # The URLs are admin-entered and the panel calls them from the server, so at least insist on a
  # web scheme: file://, gopher:// and friends have no business here.
  validates :api_url, :web_url, format: { with: %r{\Ahttps?://[^\s/]+(/\S*)?\z}i, message: :not_http }
  validate :token_reentered_for_new_api_url, on: :update
  validate :ca_certificate_must_parse

  # Set by whoever updates the connection when the token field was actually filled in (the form never
  # shows the stored token, so a blank field keeps it).
  attr_accessor :token_reentered

  # The token is sent to api_url on every call. Pointing an existing connection somewhere else while
  # keeping the stored token would hand that token to the new host — someone with only the edit form
  # (a hijacked admin session, say) could read it out that way despite it being write-only. So a new
  # API address takes a token typed in again, for that address.
  # A new CA certificate is the same lever (trust a host the admin controls, then read the token
  # off the wire), so it gets the same rule.
  def token_reentered_for_new_api_url
    return if token_reentered

    errors.add(:token, :required_with_new_api_url) if will_save_change_to_api_url?
    errors.add(:token, :required_with_new_ca_certificate) if will_save_change_to_ca_certificate?
  end

  def ca_certificate_must_parse
    OutboundHttp.parse_certificates(ca_certificate)
  rescue OpenSSL::X509::CertificateError
    errors.add(:ca_certificate, :invalid_pem)
  end

  def github? = provider == "github"
  def gitlab? = provider == "gitlab"
  def gitee? = provider == "gitee"

  CLIENTS = { "github" => "GitProviders::Github", "gitlab" => "GitProviders::Gitlab", "gitee" => "GitProviders::Gitee" }.freeze

  # Enough to tell two tokens apart in the list without showing one.
  def token_hint
    token.to_s.length > 8 ? "…#{token.to_s[-4..]}" : "…"
  end

  def client_for(repository)
    CLIENTS.fetch(provider).constantize.new(self, repository)
  end

  # Without a repository, only checks that the token works (GET /user on every provider).
  def check!
    client_for(nil).current_user
  end

  def serializable_hash(options = nil)
    super(options).except("token")
  end

  private
    def apply_defaults
      self.ca_certificate = ca_certificate.to_s.strip.presence
      defaults = DEFAULTS[provider]
      return if defaults.nil?

      self.api_url = api_url.to_s.strip.chomp("/")
      self.web_url = web_url.to_s.strip.chomp("/")
      self.api_url = derived_api_url(defaults) if api_url.blank?
      self.web_url = derived_web_url(defaults) if web_url.blank?
    end

    def derived_api_url(defaults)
      return defaults[:api_url] if web_url.blank? || web_url == defaults[:web_url]

      web_url + API_PATHS.fetch(provider)
    end

    # https://git.corp/api/v4 → https://git.corp; an API URL of some other shape falls back to its
    # scheme and host, which is where all three platforms serve their pages.
    def derived_web_url(defaults)
      return defaults[:web_url] if api_url == defaults[:api_url]

      suffix = API_PATHS.fetch(provider)
      return api_url.delete_suffix(suffix) if api_url.end_with?(suffix)

      uri = URI.parse(api_url)
      uri.host ? "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}" : api_url
    rescue URI::InvalidURIError
      api_url
    end
end
