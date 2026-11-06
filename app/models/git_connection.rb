# A read-only API token for one GitHub / GitLab instance (spec 6). Admin-managed like credentials:
# the token is encrypted, never rendered back, and only replaced as a whole.
class GitConnection < ApplicationRecord
  PROVIDERS = %w[github gitlab].freeze

  DEFAULTS = {
    "github" => { api_url: "https://api.github.com", web_url: "https://github.com" },
    "gitlab" => { api_url: "https://gitlab.com/api/v4", web_url: "https://gitlab.com" }
  }.freeze

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

  # Set by whoever updates the connection when the token field was actually filled in (the form never
  # shows the stored token, so a blank field keeps it).
  attr_accessor :token_reentered

  # The token is sent to api_url on every call. Pointing an existing connection somewhere else while
  # keeping the stored token would hand that token to the new host — someone with only the edit form
  # (a hijacked admin session, say) could read it out that way despite it being write-only. So a new
  # API address takes a token typed in again, for that address.
  def token_reentered_for_new_api_url
    return unless will_save_change_to_api_url? && !token_reentered

    errors.add(:token, :required_with_new_api_url)
  end

  def github? = provider == "github"
  def gitlab? = provider == "gitlab"

  # Enough to tell two tokens apart in the list without showing one.
  def token_hint
    token.to_s.length > 8 ? "…#{token.to_s[-4..]}" : "…"
  end

  def client_for(repository)
    (github? ? GitProviders::Github : GitProviders::Gitlab).new(self, repository)
  end

  # Without a repository, only checks that the token works (GET /user on both providers).
  def check!
    client_for(nil).current_user
  end

  def serializable_hash(options = nil)
    super(options).except("token")
  end

  private
    def apply_defaults
      defaults = DEFAULTS[provider]
      return if defaults.nil?

      self.api_url = defaults[:api_url] if api_url.blank?
      self.web_url = defaults[:web_url] if web_url.blank?
      self.api_url = api_url.to_s.strip.chomp("/")
      self.web_url = web_url.to_s.strip.chomp("/")
    end
end
