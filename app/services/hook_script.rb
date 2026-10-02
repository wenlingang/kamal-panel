# Two scripts the panel generates and the user voluntarily puts into their own project's
# .kamal/hooks/ (spec 03 §6).
# --max-time 5 and the trailing || true are mandatory: the panel being down or slow must never make the user's deploy fail.
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
