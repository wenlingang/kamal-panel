# The sidebar's two groups. Adding a section is one line in the right list: label key (under
# layouts.application), path, the controllers that count as "inside" it, an icon, and — for
# admin-only sections — the policy check that the section's controller itself uses.
module NavigationHelper
  NavItem = Data.define(:key, :path, :controllers, :icon, :badge)

  def primary_nav_items
    [
      # The app list was folded into the overview, so every page under /apps/... (an app, its
      # action output, its lock) belongs to "Overview".
      # The deploy confirm page lives under an app (/apps/:id/deploy/new), so it stays with Overview too.
      nav_item(:overview, root_path, controllers: %w[overviews managed_apps actions locks app_deploys],
               icon: "layout-grid"),
      nav_item(:deploys, deploys_path, controllers: "deploys", icon: "rocket"),
      # Open to everyone signed in: the app list inside only offers apps the person may read logs of.
      nav_item(:logs, logs_path, controllers: "logs", icon: "terminal"),
      # Open to everyone signed in; the badge is the number of alerts firing right now.
      nav_item(:alerts, alerts_path, controllers: %w[alerts alert_rules], icon: "bell",
               badge: (firing_alert_count if firing_alert_count.positive?)),
      nav_item(:audit, audit_logs_path, controllers: "audit_logs", icon: "scroll-text")
    ].compact
  end

  # Only admin sees these entries — each check uses the same policy as its controller.
  def settings_nav_items
    [
      nav_item(:people, users_path, controllers: "users", icon: "users",
               visible: policy_for(User).manage?),
      # Registry credentials are a different controller but live under /credentials/registry.
      nav_item(:credentials, credentials_path, controllers: %w[credentials registry_credentials],
               icon: "key-round", visible: policy_for(Credential).manage?),
      nav_item(:git, git_connections_path, controllers: "git_connections", icon: "git-branch",
               visible: policy_for(GitConnection).manage?),
      nav_item(:notifications, notification_channels_path, controllers: "notification_channels", icon: "send",
               visible: policy_for(NotificationChannel).manage?)
    ].compact
  end

  # Highlights by [section], not by page: /users/new still lights "People".
  def sidebar_link(item)
    current = Array(item.controllers).include?(controller.controller_path)

    link_to item.path, class: ("is-current" if current), "aria-current": ("page" if current) do
      safe_join([
        icon_tag(item.icon, size: :sm),
        tag.span(t("layouts.application.#{item.key}"), class: "side-nav-text"),
        (tag.span(item.badge, class: "side-nav-badge") if item.badge.present?)
      ].compact)
    end
  end

  private
    def nav_item(key, path, controllers:, icon:, badge: nil, visible: true)
      return nil unless visible

      NavItem.new(key:, path:, controllers:, icon:, badge:)
    end
end
