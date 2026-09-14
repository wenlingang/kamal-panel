class PasswordsMailer < ApplicationMailer
  # 按【收件人】的语言渲染，不是按发信那一刻的 I18n.locale。
  #
  # 这条是独立于请求的路径：deliver_later 在后台任务里执行，那里没有请求
  # 上下文，ApplicationController 的 around_action（见 Localization）完全
  # 帮不上忙。locale 不用调用方显式传进来——deliver_later 经 GlobalID
  # 序列化的是 user 记录本身，后台任务里 user.locale 读得到。
  def reset(user)
    @user = user

    I18n.with_locale(user.locale.presence || I18n.default_locale) do
      mail subject: t("passwords_mailer.reset.subject"), to: user.email_address
    end
  end
end
