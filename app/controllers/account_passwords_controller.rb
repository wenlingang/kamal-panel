# Changing your own password while signed in. Like LocalesController it takes no user id: the only
# password it can change is Current.user's, so there is no object to authorize. The current
# password is asked for anyway — a session left open on someone else's screen must not be enough to
# take the account over.
class AccountPasswordsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :update,
             with: -> { redirect_to edit_account_password_path, alert: I18n.t("flash.rate_limited") }

  def edit
  end

  def update
    user = Current.user

    unless user.authenticate(params[:current_password].to_s)
      return reject(t("flash.password.wrong_current"))
    end

    # has_secure_password silently ignores an empty password (it keeps the old digest), so a blank
    # submit would report success without changing anything.
    return reject(t("flash.password.blank")) if params[:password].blank?

    if user.update(params.permit(:password, :password_confirmation))
      # Everywhere else is signed out — the usual reason to change a password is suspecting someone
      # else has it. The session doing the change stays.
      user.sessions.where.not(id: Current.session.id).destroy_all
      AuditLog.record_access!(user:, action_name: "user.change_password", target_user: user)

      redirect_to root_path, notice: t("flash.password.changed")
    else
      reject(user.errors.full_messages.to_sentence)
    end
  end

  private
    def reject(message)
      flash.now[:alert] = message
      render :edit, status: :unprocessable_entity
    end
end
