module ApplicationHelper
  # Lucide (ISC) paths are inlined by hand under app/views/shared/icons/. label is given only when
  # the icon stands on its own (icon-only buttons); without it, it renders as aria-hidden.
  def icon_tag(name, size: :md, label: nil, css: nil)
    klass = [ "icon", "icon-#{size}", css ].compact.join(" ")
    a11y = label ? { role: "img", "aria-label": label } : { "aria-hidden": "true", focusable: "false" }

    tag.svg(**a11y, class: klass, viewBox: "0 0 24 24", fill: "none",
            stroke: "currentColor", "stroke-width": "1.5",
            "stroke-linecap": "round", "stroke-linejoin": "round") do
      render("shared/icons/#{name}")
    end
  end

  # indistinguishable for people with color-vision deficiency and in black-and-white printing.
  STATUS_ICONS = {
    "ok" => "circle-check",
    "drift" => "triangle-alert",
    "unhealthy" => "circle-x",
    "unreachable" => "plug",
    "stale" => "clock",
    "unparseable" => "circle-help",
    "unknown" => "circle-help"
  }.freeze

  FLASH_ICONS = { "notice" => "info", "warning" => "triangle-alert", "alert" => "circle-alert" }.freeze

  def flash_icon(type) = FLASH_ICONS.fetch(type.to_s, "info")

  # icon_key picks the icon when it differs from the colour tier (stale data sits in the
  # unreachable tier but gets its own icon).
  def status_badge(level, label, icon_key: level)
    tag.span(class: "status-badge status-#{level}") do
      icon_tag(STATUS_ICONS.fetch(icon_key.to_s, "circle-help"), size: :sm) + label.to_s
    end
  end

  # The top nav highlights by [section], not by page.
  def nav_link_to(label, path, controllers:, icon: nil)
    current = Array(controllers).include?(controller.controller_path)

    link_to path, class: ("is-current" if current) do
      icon ? icon_tag(icon, size: :sm) + label.to_s : label.to_s
    end
  end

  # An absent value ("not configured", "none yet"): muted so it reads as absence rather than data.
  # Not wrapped in brackets: a leading full-width bracket pushes the text off its column.
  def placeholder(text) = tag.span(text, class: "placeholder")

  # How long an action ran, in the unit people think in: "380 ms", "3.0 s", "1 min 5 s".
  def duration_text(ms)
    return "—" if ms.nil?
    return t("duration.ms", count: ms) if ms < 1000
    return t("duration.seconds", count: format("%.1f", ms / 1000.0)) if ms < 60_000

    minutes, seconds = (ms / 1000).divmod(60)
    t("duration.minutes", minutes:, seconds:)
  end

  # A moment shown in full: one format across pages, with the exact instant on hover.
  def timestamp(time)
    time_tag(time, l(time, format: :panel), title: time.iso8601)
  end

  def joined_list(items, empty: nil)
    items.join(t("common.list_separator")).presence || empty
  end

  def app_name_list(apps, empty:) = joined_list(apps.map(&:name), empty:)

  LOCALE_LABELS = { "zh-CN" => "中", "en" => "EN" }.freeze

  def locale_label(locale) = LOCALE_LABELS.fetch(locale, locale)

  def user_identity(user)
    return "" if user.nil?
    return user.email_address if user.nickname.blank?

    "#{user.nickname} <#{user.email_address}>"
  end

  # The action name.
  def audit_action_label(log)
    t("audit.actions.#{log.action_name}", default: log.action_name)
  end

  # Deploy-type rows link to their recorded output, but only for someone allowed to run that
  # action: the output page applies the same check, and a link that bounces is worse than none.
  def audit_action_link(log)
    label = audit_action_label(log)
    action_class = Actions::Base.registry[log.action_name]
    return label unless log.managed_app && action_class
    return label unless ManagedAppPolicy.new(Current.user, log.managed_app).run?(action_class)

    link_to label, managed_app_action_path(log.managed_app, log)
  end

  def audit_object(log)
    subject =
      if log.target_user           then user_identity(log.target_user)
      elsif log.target_version.present? then log.target_version
      end
    note = audit_detail_text(log)

    return note || "—" if subject.blank?
    return subject if note.blank?

    "#{subject}#{t('audit.note_wrapper', note: note)}"
  end

  private
    # that category — proper names like credential names and app names, where translating would
    # actually be wrong — as well as all historical rows.
    def audit_detail_text(log)
      return t("audit.details.#{log.detail_key}", **audit_detail_args(log)) if log.detail_key.present?

      log.detail.presence
    end

    # What people want to see is "SSH private key". The connector itself is also language-dependent,
    # so it goes through the translations too.
    def audit_detail_args(log)
      args = log.detail_args.symbolize_keys

      if args[:fields].is_a?(Array)
        args[:fields] = args[:fields]
                          .map { |field| ManagedApp.human_attribute_name(field.sub(/_id\z/, "")) }
                          .join(t("common.list_separator"))
      end

      args
    end
end
