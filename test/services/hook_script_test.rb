require "test_helper"

class HookScriptTest < ActiveSupport::TestCase
  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    @script = HookScript.new(@app, base_url: "https://panel.example.com", token: "T0KEN")
  end

  test "has a shebang and a filename comment and runs directly after chmod +x" do
    assert_match(/\A#!\/bin\/sh\n/, @script.pre_deploy)
    assert_match(/\A#!\/bin\/sh\n/, @script.post_deploy)
    assert_match "# .kamal/hooks/pre-deploy", @script.pre_deploy
    assert_match "# .kamal/hooks/post-deploy", @script.post_deploy
  end

  test "the two scripts differ only in phase" do
    assert_match "phase=started", @script.pre_deploy
    assert_match "phase=succeeded", @script.post_deploy
  end

  test "a panel outage must not break the user's deploy" do
    [ @script.pre_deploy, @script.post_deploy ].each do |body|
      assert_match "--max-time 5", body
      assert_match "|| true", body
    end
  end

  test "includes the endpoint and token" do
    assert_match "https://panel.example.com/api/deploys", @script.pre_deploy
    assert_match "Authorization: Bearer T0KEN", @script.pre_deploy
  end

  test "sends Kamal's own environment variables" do
    %w[KAMAL_SERVICE KAMAL_DESTINATION KAMAL_VERSION KAMAL_PERFORMER
       KAMAL_RECORDED_AT KAMAL_COMMAND].each do |var|
      assert_match var, @script.post_deploy
    end
  end
end
