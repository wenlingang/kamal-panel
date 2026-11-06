# Versions, commits and deploy outcomes as the deploy pages, history and overview show them.
# Nothing here calls out: links are built from the Git connection's web URL and the repository.
module DeploysHelper
  FULL_SHA = /\A\h{40}\z/
  SHA_LIKE = /\A\h{7,40}\z/

  CI_BADGES = {
    "success" => [ "ok", "circle-check" ],
    "failure" => [ "unhealthy", "circle-x" ],
    "running" => [ "drift", "loader-circle" ],
    "pending" => [ "drift", "clock" ],
    "none"    => [ "unknown", "circle-help" ],
    "unknown" => [ "unknown", "circle-help" ]
  }.freeze

  IMAGE_BADGES = {
    present: [ "ok", "box" ],
    missing: [ "unhealthy", "circle-x" ],
    unknown: [ "unknown", "circle-help" ]
  }.freeze

  RESULT_BADGES = {
    success: [ "ok", "circle-check" ],
    failure: [ "unhealthy", "circle-x" ],
    running: [ "unknown", "loader-circle" ],
    unfinished: [ "drift", "triangle-alert" ],
    not_run: [ "unreachable", "circle-alert" ]
  }.freeze

  # A full sha reads as noise in a table; the short form is what people say out loud. The full
  # value stays in the title.
  def display_version(version)
    version.to_s.match?(FULL_SHA) ? version.to_s[0, ManagedApp::SHORT_SHA_LENGTH] : version.to_s
  end

  def version_url(managed_app, version)
    client = managed_app.git_client
    return nil if client.nil? || version.blank?

    if managed_app.version_format == "tag" then client.tag_url(version)
    elsif version.to_s.match?(SHA_LIKE) then client.commit_url(version)
    end
  end

  # The version as text, linked to its commit (or tag) when the app's repository is configured.
  def version_link(managed_app, version)
    return placeholder("—") if version.blank?

    label = display_version(version)
    title = (version if label != version)
    url = version_url(managed_app, version)

    if url
      link_to label, url, class: "mono version-link", title: title, target: "_blank", rel: "noopener noreferrer"
    else
      tag.span(label, class: "mono", title: title)
    end
  end

  def version_links(managed_app, versions)
    safe_join(versions.map { |version| version_link(managed_app, version) }, " / ")
  end

  def ci_badge(status)
    tier, icon = CI_BADGES.fetch(status.to_s, CI_BADGES["unknown"])
    deploy_badge(tier, icon, t("deploys.ci.#{CI_BADGES.key?(status.to_s) ? status : 'unknown'}"))
  end

  def image_badge(status)
    tier, icon = IMAGE_BADGES.fetch(status.to_sym, IMAGE_BADGES[:unknown])
    deploy_badge(tier, icon, t("deploys.image.#{IMAGE_BADGES.key?(status.to_sym) ? status : 'unknown'}"))
  end

  def deploy_result_badge(result)
    tier, icon = RESULT_BADGES.fetch(result.to_sym)
    deploy_badge(tier, icon, t("deploys.results.#{result}"))
  end

  def live_badge = deploy_badge("ok", "zap", t("deploys.live"))

  # The author's avatar, or their initial when the platform has none.
  def author_avatar(commit)
    if commit.author_avatar.present?
      image_tag(commit.author_avatar, alt: "", class: "avatar", loading: "lazy", referrerpolicy: "no-referrer")
    else
      tag.span(commit.author_name.to_s.first.to_s.upcase.presence || "?", class: "avatar avatar-initial", "aria-hidden": "true")
    end
  end

  def deploy_source_text(source)
    t({ "inferred" => "deploy_events.inferred", "panel" => "deploy_events.panel" }
        .fetch(source, "deploy_events.hook_reported"))
  end

  private
    def deploy_badge(tier, icon, label)
      tag.span(class: "status-badge status-#{tier}") { icon_tag(icon, size: :sm) + label }
    end
end
