module AuthorizationHelper
  def allowed_to(capability, record, &block)
    capture(&block) if policy_for(record).public_send("#{capability}?")
  end
end
