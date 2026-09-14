module ApplicationHelper
  # 顶部导航按【版块】高亮，不按页面。
  #
  # 原来用的是 current_page?(users_path)，那是整条 URL 的精确比对：一进
  # /users/new 就不再等于 /users，高亮整个消失，人在子页面里看不出自己
  # 身在哪一栏。改成认控制器——一个版块可能横跨多个控制器（镜像库凭据
  # 是 RegistryCredentialsController，但挂在 /credentials/registry 下，
  # 对用户来说就是「凭据」那一栏里的东西），所以收的是一组控制器名。
  def nav_link_to(label, path, controllers:)
    current = Array(controllers).include?(controller.controller_path)
    link_to label, path, class: ("is-current" if current)
  end

  # 应用名列表。连接符是语言相关的（中文顿号、英文逗号加空格），所以不能在
  # 视图里直接写 join("、")——那是这批改动里最容易漏掉的一处，因为它不长得
  # 像一句文案。应用名本身是专名，不翻译（设计 12 §2.2 的判据）。
  def joined_list(items, empty: nil)
    items.join(t("common.list_separator")).presence || empty
  end

  def app_name_list(apps, empty:) = joined_list(apps.map(&:name), empty:)

  # 切换器上的标签。刻意不走 t()：这两个标签在【任何】语言下都该显示成
  # 「中 / EN」——一个正在看英文界面、想切回中文的人，需要认出那个字，
  # 而不是读懂一句英文说明。
  LOCALE_LABELS = { "zh-CN" => "中", "en" => "EN" }.freeze

  def locale_label(locale) = LOCALE_LABELS.fetch(locale, locale)

  # 审计页上称呼一个人的写法：「昵称 <邮箱>」。追责看的是邮箱，日常辨认看的
  # 是昵称，所以两个都给——昵称不要求唯一，只给昵称的话两个重名的人在审计
  # 页上就分不出来了。没填昵称时只显示邮箱，不要留一对空的尖括号。
  def user_identity(user)
    return "" if user.nil?
    return user.email_address if user.nickname.blank?

    "#{user.nickname} <#{user.email_address}>"
  end

  # 动作名。认不出就退回原始字符串——代码里改过名、审计行还留着旧名时不能崩，
  # 也不该在页面上显示成 "translation missing"。这条退路会掩盖"新加动作忘了
  # 写译文"，所以有 AuditLogTest 正面盯着译文覆盖（AuditLog.all_action_names）。
  def audit_action_label(log)
    t("audit.actions.#{log.action_name}", default: log.action_name)
  end

  # 「对象」这一列装着三种结构上不同的东西，按确定性从高到低取：
  #   1. 被操作的人   2. 目标版本号   3. 对象文本
  # 只有第三种需要翻译，而它自己又分两路：detail_key 是可翻译的那一类；
  # detail 是不需要翻译的那一类——凭据名、应用名这种专名，翻了反而是错的
  # ——以及所有历史行（它们只有 detail）。
  def audit_object(log)
    subject =
      if log.target_user           then user_identity(log.target_user)
      elsif log.target_version.present? then log.target_version
      end
    note = audit_detail_text(log)

    return note || "—" if subject.blank?
    return subject if note.blank?

    # 两者都有时【都要显示】。此前这一列是"取第一个非空"，user.create 同时
    # 写了 target_user 和 detail，于是"密码由管理员直接设置"从来没露过面
    # ——一次只写不显的记录，等于没记。括号本身也是语言相关的，走译文。
    "#{subject}#{t('audit.note_wrapper', note: note)}"
  end

  private
    # 对象文本的两条路：detail_key 是可翻译的那一类；detail 是不需要翻译的
    # 那一类——凭据名、应用名这种专名，翻了反而是错的——以及所有历史行。
    def audit_detail_text(log)
      return t("audit.details.#{log.detail_key}", **audit_detail_args(log)) if log.detail_key.present?

      log.detail.presence
    end

    # 字段名要逐个翻译再拼：存进 detail_args 的是列名（ssh_credential_id），
    # 人要看的是"SSH 私钥"。连接符本身也是语言相关的，所以也走译文。
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
