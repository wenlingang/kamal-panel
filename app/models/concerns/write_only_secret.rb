module WriteOnlySecret
  extend ActiveSupport::Concern

  included do
    encrypts :value

    validates :value, presence: true
    validates :name, presence: true, uniqueness: true
  end

  # encryption filters this automatically, but the serialization path is not under its jurisdiction,
  # so an explicit safeguard is needed here.
  def serializable_hash(options = nil)
    super(options).except("value")
  end
end
