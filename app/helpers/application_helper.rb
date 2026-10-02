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
    "unknown" => "circle-help"
  }.freeze

  FLASH_ICONS = { "notice" => "info", "warning" => "triangle-alert", "alert" => "circle-alert" }.freeze

  def flash_icon(type) = FLASH_ICONS.fetch(type.to_s, "info")

  def status_badge(level, label)
    tag.span(class: "status-badge status-#{level}") do
      icon_tag(STATUS_ICONS.fetch(level.to_s, "circle-help"), size: :sm) + label.to_s
    end
  end

  # The top nav highlights by [section], not by page.
  def nav_link_to(label, path, controllers:, icon: nil)
    current = Array(controllers).include?(controller.controller_path)

    link_to path, class: ("is-current" if current) do
      icon ? icon_tag(icon, size: :sm) + label.to_s : label.to_s
    end
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
