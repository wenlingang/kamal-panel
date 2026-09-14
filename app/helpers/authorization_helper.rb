module AuthorizationHelper
  # 视图里看得见的按钮，和控制器放行的动作，必须是同一句话算出来的——
  # 这个帮助器调的就是控制器调的那个 policy 方法。此前 operator_only 与
  # require_operator! 各自独立判断同一件事，两处一致纯属巧合。
  def allowed_to(capability, record, &block)
    capture(&block) if policy_for(record).public_send("#{capability}?")
  end
end
