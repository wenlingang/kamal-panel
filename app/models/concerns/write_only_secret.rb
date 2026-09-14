# 两种凭据（SSH 私钥、registry 密码）真正共享的只有三件事，这里也只有这三件：
# 加密存储、有一个唯一的名字、以及永远不把明文序列化出去。
#
# 别的一概不进。SSH 那套独立子进程加硬超时的校验、指纹、16 KiB 上限留在
# Credential 自己身上——它们是针对"把攻击者可控的字节喂给 net-ssh 这个第三方
# 解析器"这个具体风险写的，而 registry 密码是一个不透明字符串，没有解析器，
# 也就没有那个风险。把它们放进这里，会让下一个读代码的人以为那套防护对
# registry 密码也成立。
module WriteOnlySecret
  extend ActiveSupport::Concern

  included do
    encrypts :value

    validates :value, presence: true
    validates :name, presence: true, uniqueness: true
  end

  # 防止 to_json / as_json 意外把明文序列化出去。#inspect 已由 Active Record
  # encryption 自动过滤，但序列化路径不受它管辖，需要在这里显式兜底。
  def serializable_hash(options = nil)
    super(options).except("value")
  end
end
