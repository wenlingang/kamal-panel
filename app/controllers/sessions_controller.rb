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
      # render 而不是 redirect：重定向会把人刚填的邮箱一起丢掉，而错的通常
      # 只是密码，让他把邮箱重打一遍是纯粹的惩罚。视图里的
      # value: params[:email_address] 本来就是为这条路准备的，此前因为走
      # 重定向而一直没生效。仓库里其他表单失败时也都是 render + 422。
      flash.now[:alert] = t("flash.bad_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
