require "test_helper"

# Reported fields are fully isolated from write-action parameters: an action's cli_args is generated
# by the closed action set itself. This must be pinned explicitly, rather than relying on "I know
# they aren't connected".
class Api::DeploysIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @token = @managed_app.regenerate_hook_token!
  end

  test "rejects a version containing shell metacharacters without persisting it" do
    [ "a; rm -rf /", "$(whoami)", "`id`", "../../etc/passwd", "a b" ].each do |bad|
      post "/api/deploys",
           params: { phase: "succeeded", service: "blog", destination: "production",
                     version: bad, performer: "ci", command: "deploy" },
           headers: { "Authorization" => "Bearer #{@token}" }

      assert_response :unprocessable_entity, "#{bad.inspect} should not be accepted"
    end

    assert_equal 0, DeployEvent.count
  end

  test "a reported version never ends up in any action's cli_args" do
    post "/api/deploys",
         params: { phase: "succeeded", service: "blog", destination: "production",
                   version: "aaaaaaa", performer: "ci", command: "deploy" },
         headers: { "Authorization" => "Bearer #{@token}" }
    assert_response :no_content

    # The action's version comes from the target_version explicitly passed by the caller, unrelated
    # to the report
    args = Actions::Restart.new(@managed_app, target_version: "bbbbbbb").cli_args

    assert_includes args, "bbbbbbb"
    refute_includes args.join(" "), "aaaaaaa"
  end
end
