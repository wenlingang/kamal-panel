module WriteOnlySecret
  extend ActiveSupport::Concern

  included do
    encrypts :value

    validates :value, presence: true
    validates :name, presence: true, uniqueness: true
  end

  # encryption 自动过滤，但序列化路径不受它管辖，需要在这里显式兜底。
  def serializable_hash(options = nil)
    super(options).except("value")
  end
end
