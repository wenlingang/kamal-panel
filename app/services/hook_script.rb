# 面板生成、用户自愿放进自己项目的 .kamal/hooks/ 的两段脚本（spec 03 第 6 节）。
#
# --max-time 5 与结尾的 || true 都是硬性的：面板挂掉或变慢，绝不能让
# 用户的部署失败或卡住。没有这两样，没人敢加这个 hook。
class HookScript
  def initialize(managed_app, base_url:, token:)
    @managed_app = managed_app
    @base_url = base_url.to_s.chomp("/")
    @token = token
  end

  def pre_deploy  = script("pre-deploy", "started")
  def post_deploy = script("post-deploy", "succeeded")

  private
    attr_reader :managed_app, :base_url, :token

    def script(filename, phase)
      <<~SH
        #!/bin/sh
        # .kamal/hooks/#{filename}
        curl -sf --max-time 5 -X POST "#{base_url}/api/deploys" \\
          -H "Authorization: Bearer #{token}" \\
          -d phase=#{phase} \\
          -d service="$KAMAL_SERVICE" -d destination="$KAMAL_DESTINATION" \\
          -d version="$KAMAL_VERSION" -d performer="$KAMAL_PERFORMER" \\
          -d recorded_at="$KAMAL_RECORDED_AT" -d command="$KAMAL_COMMAND" || true
      SH
    end
end
