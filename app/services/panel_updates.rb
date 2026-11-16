# Whether a newer release of the panel is out. Once a day CheckPanelUpdatesJob asks GitHub for the
# repository's tags (an anonymous public API call: nothing about this panel is sent) and remembers
# the newest vX.Y.Z; admins see a line in the layout when it is newer than the running version.
#
# Off for a build without a version (PANEL_VERSION unset or "dev": a local or source build has no
# release to compare with), and when PANEL_UPDATE_CHECK=false.
module PanelUpdates
  REPOSITORY = "wenlingang/kamal-panel".freeze
  CACHE_KEY = "panel_updates/latest".freeze
  TAG = /\Av?(\d+)\.(\d+)\.(\d+)\z/

  module_function

  def current = ENV.fetch("PANEL_VERSION", "dev").to_s.delete_prefix("v")

  def enabled?
    ENV.fetch("PANEL_UPDATE_CHECK", "true") != "false" && TAG.match?(current)
  end

  # Asks GitHub and caches the answer; keeps the previous answer when GitHub can't be reached.
  def check!
    return nil unless enabled?

    response = OutboundHttp.request(:get, "https://api.github.com/repos/#{REPOSITORY}/tags?per_page=100",
                                    headers: { "Accept" => "application/vnd.github+json" })
    return latest unless response.is_a?(Net::HTTPSuccess)

    newest = JSON.parse(response.body).filter_map { |tag| tag["name"] if TAG.match?(tag["name"].to_s) }
                 .max_by { |name| version_key(name) }
    Rails.cache.write(CACHE_KEY, newest.delete_prefix("v")) if newest
    latest
  rescue OutboundHttp::Error, JSON::ParserError
    latest
  end

  def latest = Rails.cache.read(CACHE_KEY)

  # The newer version to mention, or nil.
  def available
    return nil unless enabled? && latest

    (version_key(latest) <=> version_key(current)) == 1 ? latest : nil
  end

  def release_url(version) = "https://github.com/#{REPOSITORY}/releases/tag/v#{version}"

  def version_key(name) = name.to_s.match(TAG)&.captures&.map(&:to_i) || [ 0, 0, 0 ]
end
