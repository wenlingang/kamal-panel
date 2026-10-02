class RegistryCredentialsController < ApplicationController
  include BlockedCredentialAlert

  authorize :manage, on: RegistryCredential, only: %i[ new create edit update destroy ]

  before_action :set_credential, only: %i[ edit update destroy ]

  # 没有 index：两种凭据列在同一页（CredentialsController#index）。

  def new
    @credential = RegistryCredential.new
  end

  def create
    @credential = RegistryCredential.new(create_params)

    if @credential.save
      AuditLog.record_access!(user: Current.user, action_name: "registry_credential.create",
                              detail: @credential.name)
      redirect_to credentials_path, notice: t("flash.credential.added", name: @credential.name)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  # 只换 value：名字不动，因为名字是别人引用这条凭据的方式。换了之后【立刻】
  # 对所有引用它的应用生效——这是一次多应用操作，视图要把受影响的应用列出来。
  def update
    if @credential.update(rotate_params)
      AuditLog.record_access!(user: Current.user, action_name: "registry_credential.rotate",
                              detail: @credential.name)
      redirect_to credentials_path, notice: t("flash.credential.replaced", name: @credential.name)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @credential.name

    if @credential.destroy
      AuditLog.record_access!(user: Current.user, action_name: "registry_credential.delete",
                              detail: name)
      redirect_to credentials_path, notice: t("flash.credential.deleted", name: name)
    else
      redirect_to credentials_path, alert: blocked_destroy_alert(@credential)
    end
  end

  private
    def set_credential = @credential = RegistryCredential.find(params[:id])

    def create_params = params.expect(registry_credential: [ :name, :value, :server ])

    # 轮换只收 value：名字与 server 不在这里改。
    def rotate_params = params.expect(registry_credential: [ :value ])
end
