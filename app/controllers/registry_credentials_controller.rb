class RegistryCredentialsController < ApplicationController
  include BlockedCredentialAlert

  authorize :manage, on: RegistryCredential, only: %i[ new create edit update destroy ]

  before_action :set_credential, only: %i[ edit update destroy ]

  # No index: both kinds of credentials are listed on the same page (CredentialsController#index).

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

  # Only change value: the name stays put, because the name is how others reference this credential.
  # After the change it takes effect [immediately] for every app that references it — this is a
  # multi-app operation, so the view must list the affected apps.
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

    # Rotation only accepts value: the name and server are not changed here.
    def rotate_params = params.expect(registry_credential: [ :value ])
end
