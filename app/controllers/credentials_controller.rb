class CredentialsController < ApplicationController
  include BlockedCredentialAlert

  authorize :manage, on: Credential, only: %i[ index new create edit update destroy ]

  before_action :set_credential, only: %i[ edit update destroy ]

  def index
    @credentials = Credential.includes(:managed_apps).order(:name)
    @registry_credentials = RegistryCredential.includes(:managed_apps).order(:name)
  end

  def new
    @credential = Credential.new
  end

  def create
    @credential = Credential.new(create_params.merge(kind: "ssh_key"))

    if @credential.save
      AuditLog.record_access!(user: Current.user, action_name: "credential.create",
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
      AuditLog.record_access!(user: Current.user, action_name: "credential.rotate",
                              detail: @credential.name)
      redirect_to credentials_path, notice: t("flash.credential.replaced", name: @credential.name)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @credential.name

    if @credential.destroy
      AuditLog.record_access!(user: Current.user, action_name: "credential.delete", detail: name)
      redirect_to credentials_path, notice: t("flash.credential.deleted", name: name)
    else
      redirect_to credentials_path, alert: blocked_destroy_alert(@credential)
    end
  end

  private
    def set_credential = @credential = Credential.find(params[:id])

    def create_params = params.expect(credential: [ :name, :value ])

    # Rotation only accepts value: the name is not changed here.
    def rotate_params = params.expect(credential: [ :value ])
end
