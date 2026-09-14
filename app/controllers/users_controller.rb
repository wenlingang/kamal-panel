class UsersController < ApplicationController
  authorize :manage, on: User, only: %i[ index new create edit update deactivate reactivate ]

  before_action :set_user, only: %i[ edit update deactivate reactivate ]
  before_action :set_password_setup, only: :create

  def index
    @users = User.includes(:managed_apps).order(:email_address)
  end

  def new
    @user = User.new(role: "ops")
    @password_setup = "mail"
  end

  # 默认仍走找回密码那条路：admin 不知道别人的密码是更好的默认值，也不必
  # 为「邀请」新造一条认证路径。但邮件不是到处都送得到（内网无外发、对方
  # 收件被拦），所以留一条由 admin 直接设密码的路——两条都汇到同一个
  # has_secure_password，没有第二套认证逻辑。
  def create
    @user = User.new(create_params)

    if manual_password?
      @user.assign_attributes(password_params)
    else
      # 这个随机值只为满足 has_secure_password 的 presence 校验：谁都不知道
      # 它，账号在对方点开邮件里的链接之前登不进来。
      @user.password = SecureRandom.hex(32)
    end

    if @user.save
      AuditLog.record_access!(user: Current.user, action_name: "user.create",
                              target_user: @user, detail_key: password_setup_detail_key)

      if manual_password?
        redirect_to users_path,
                    notice: t("flash.user.created_with_password", email: @user.email_address)
      else
        PasswordsMailer.reset(@user).deliver_later
        redirect_to users_path,
                    notice: t("flash.user.created_with_mail", email: @user.email_address)
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @managed_apps = ManagedApp.order(:name)
  end

  def update
    new_role = update_params[:role]

    if demoting_last_admin?(new_role)
      return redirect_to edit_user_path(@user), alert: t("flash.user.last_admin_demote")
    end

    role_changed = new_role.present? && new_role != @user.role
    updated = false

    # 角色改动、成员增删要么一起成立要么一起不成立。分开写的话，成员循环中途
    # 抛异常会留下"角色已改、成员只改了一半"的现场，而审计看上去像是都做了。
    @user.transaction do
      if (updated = @user.update(update_params))
        if role_changed
          AuditLog.record_access!(user: Current.user, action_name: "user.update_role",
                                  target_user: @user)
        end
        sync_memberships
      end
    end

    if updated
      redirect_to users_path, notice: t("flash.user.updated", email: @user.email_address)
    else
      @managed_apps = ManagedApp.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def deactivate
    if last_admin?(@user)
      return redirect_to users_path, alert: t("flash.user.last_admin_deactivate")
    end

    @user.deactivate!
    AuditLog.record_access!(user: Current.user, action_name: "user.deactivate", target_user: @user)
    redirect_to users_path, notice: t("flash.user.deactivated", email: @user.email_address)
  end

  def reactivate
    @user.reactivate!
    AuditLog.record_access!(user: Current.user, action_name: "user.reactivate", target_user: @user)
    redirect_to users_path, notice: t("flash.user.reactivated", email: @user.email_address)
  end

  private
    def set_user = @user = User.find(params[:id])

    # 只认 "manual"，其余一律当成发邮件：这个值既决定行为，又要在校验失败
    # 退回表单时回填给视图，收敛成两个确定值比到处判断 params 安全。
    def set_password_setup = @password_setup = params[:password_setup] == "manual" ? "manual" : "mail"

    def manual_password? = @password_setup == "manual"

    # 存 key 不存中文：审计行只增不删，写进中文就等于把语言永久焊死在数据里。
    def password_setup_detail_key
      manual_password? ? "user.password_by_admin" : "user.password_by_mail"
    end

    def create_params = params.expect(user: [ :email_address, :role, :nickname ])

    def password_params = params.expect(user: [ :password, :password_confirmation ])

    # update 不收 :email_address。编辑页本来就只渲染角色与成员，但参数是可以伪造的：
    # 允许改邮箱等于允许改别人的登录名，改完再走公开的找回密码流程就接管了那个账号
    # ——而这条路径在角色没同时变化时连一行审计都不写。换邮箱的正确做法是停用旧账号、
    # 建一个新的，这样审计里的每一行也始终指得回当时那个人。
    def update_params = params.expect(user: [ :role, :nickname ])

    # 成员关系的写入口只有这一处（设计 11 第 5.2 节）：应用详情页只读展示。
    # 两处都能编辑意味着两套表单、两条写路径，以及它们迟早不一致。
    def sync_memberships
      # 这张表只放 developer 的行（设计 11 第 2.2 节：admin 与 ops 永远不进这张表）。
      # 要挡住的不是"表里多几行"，而是这条：developer 降成 ops 时若把行留着，
      # 日后再升回 developer，他名下的那批应用会原样复活——没有人做过这个决定，
      # 界面上也不会有任何提示。所以非 developer 一律清空。
      wanted =
        if @user.developer?
          # 编辑页那个"全不勾也要提交"的隐藏字段会带来一个空字符串，它 to_i 是 0，
          # 而不存在 id 为 0 的应用——不滤掉就会在 create! 上抛外键错误。
          Array(params[:managed_app_ids]).map(&:to_i).reject(&:zero?)
        else
          []
        end
      current = @user.managed_app_ids

      (wanted - current).each do |app_id|
        AppMembership.create!(user: @user, managed_app_id: app_id)
        AuditLog.record_access!(user: Current.user, action_name: "app.add_member",
                                target_user: @user, managed_app_id: app_id)
      end

      (current - wanted).each do |app_id|
        AppMembership.where(user: @user, managed_app_id: app_id).destroy_all
        AuditLog.record_access!(user: Current.user, action_name: "app.remove_member",
                                target_user: @user, managed_app_id: app_id)
      end
    end

    # 面板一旦没有 admin，就再也没有人能管人、管凭据、接入应用——恢复它需要
    # 去服务器上开 rails console。这是单向的死局，必须在发生之前拦住。
    def last_admin?(user)
      user.admin? && User.active.where(role: "admin").where.not(id: user.id).none?
    end

    def demoting_last_admin?(new_role)
      new_role.present? && new_role != "admin" && last_admin?(@user)
    end
end
