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

  def create
    @user = User.new(create_params)

    if manual_password?
      @user.assign_attributes(password_params)
    else
      # it; the account cannot log in until the person clicks the link in the email.
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

    # Raising an exception would leave a scene of "role changed, memberships only half changed",
    # while the audit would look as if both were done.
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

    # Filled back into the view when the form is re-rendered; narrowing it to two definite values is
    # safer than checking params everywhere.
    def set_password_setup = @password_setup = params[:password_setup] == "manual" ? "manual" : "mail"

    def manual_password? = @password_setup == "manual"

    # Store the key, not Chinese text: audit rows are append-only, and writing Chinese in would weld
    # the language permanently into the data.
    def password_setup_detail_key
      manual_password? ? "user.password_by_admin" : "user.password_by_mail"
    end

    def create_params = params.expect(user: [ :email_address, :role, :nickname ])

    def password_params = params.expect(user: [ :password, :password_confirmation ])

    # update does not accept :email_address.
    def update_params = params.expect(user: [ :role, :nickname ])

    # Membership has only this one write entry point (design 11 §5.2): the app detail page is
    # read-only display. Editing in both places would mean two forms, two write paths, and the two
    # being inconsistent sooner or later.
    def sync_memberships
      # This table holds only developer rows (design 11 §2.2: admin and ops never go in this table).
      wanted =
        if @user.developer?
          # while no app with id 0 exists — without filtering it out, create! would raise a
          # foreign-key error.
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

    # and go onto the server to open a rails console. That is a one-way dead end and must be stopped
    # before it happens.
    def last_admin?(user)
      user.admin? && User.active.where(role: "admin").where.not(id: user.id).none?
    end

    def demoting_last_admin?(new_role)
      new_role.present? && new_role != "admin" && last_admin?(@user)
    end
end
