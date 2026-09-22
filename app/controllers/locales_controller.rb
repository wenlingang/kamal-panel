class LocalesController < ApplicationController
  # 不收 user id：没有「帮别人换语言」这条路径，也就没有需要授权的对象。
  # 这也是它没有 policy 的原因——能改的永远只有自己。
  def update
    Current.user.update(locale: params[:locale])

    # 跳回哪一页，拿不到或是外站都只会退到首页。
    redirect_back fallback_location: root_path
  end
end
