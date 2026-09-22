class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: I18n.t("flash.rate_limited") }

  def new
  end

  def create
    user = User.authenticate_by(params.permit(:email_address, :password))

    # 停用的账号与密码错误给同一句话：区别对待等于向未认证的人确认这个邮箱存在。
    if user && !user.deactivated?
      start_new_session_for user
      redirect_to after_authentication_url
    else
      flash.now[:alert] = t("flash.bad_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
