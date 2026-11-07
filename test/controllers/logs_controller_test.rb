require "test_helper"

class LogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # The rate limit counts in the cache; a previous test's query must not count against this one.
    Rails.cache.clear
    @credential = Credential.create!(kind: "ssh_key", name: "key", value: FakeHost.private_key)
    @blog = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production", ssh_credential: @credential)
    @shop = ManagedApp.create!(name: "shop", config_yaml: file_fixture("accessory_deploy.yml").read,
                               destination: "staging")
    @developer = users(:three)
    AppMembership.create!(user: @developer, managed_app: @blog)
  end

  test "another app's id is rejected on the page and on the results" do
    sign_in_as @developer

    get logs_path(app: @shop.id)
    assert_redirected_to root_path

    get logs_results_path(app: @shop.id)
    assert_redirected_to root_path
  end
end

# The whole path with a real SSH round against the fake hosts: rows render escaped, with the
# keyword highlighted.
class LogsControllerFakeHostTest < ActionDispatch::IntegrationTest
  setup do
    FakeHost.ensure_ready!
    FakeHost.reset_all!
    Rails.cache.clear
    @managed_app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production",
                              ssh_credential: Credential.create!(kind: "ssh_key", name: "key", value: FakeHost.private_key))
    container = FakeHost.seed_container(node: "node-1", service: "blog", role: "web", destination: "production",
                                        version: "aaaaaaa",
                                        command: "echo '<script>alert(1)</script> Boom'; echo 'WARN quiet'; sleep 3600")
    sleep 1
    Observation.create!(managed_app: @managed_app, host: "127.0.0.1", role: "web", container_name: container,
                        docker_status: "running", version: "aaaaaaa", reachable: true, observed_at: Time.current)
  end
end
