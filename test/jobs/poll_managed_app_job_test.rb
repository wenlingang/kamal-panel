require "test_helper"

class PollManagedAppJobTest < ExecutionLayerTest
  include ActionCable::TestHelper

  setup do
    FakeHost.start_proxy("node-1")
  end

  def build_app
    yaml = <<~YAML
      service: blog
      image: example/blog
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
      ssh:
        user: deploy
        port: #{FakeHost::NODES.fetch("node-1")}
    YAML

    app_name = "blog-#{SecureRandom.hex(4)}"
    ManagedApp.create!(
      name: app_name, config_yaml: yaml, destination: "production",
      ssh_credential: Credential.new(kind: "ssh_key", value: FakeHost.private_key,
                                      name: "#{app_name} 的 SSH 私钥")
    )
  end

  test "a poll writes both container observations and the routing snapshot" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app
    PollManagedAppJob.perform_now(app)

    assert_equal "aaaaaaa", Observation.latest_for(app).first.version

    target = ProxyTarget.where(managed_app: app).sole
    assert_equal "blog-web-production", target.service_name
    assert_match(/blog-web-production-aaaaaaa/, target.target)
  end

  # What gets broadcast is a signal rather than a rendered grid: the overview page supports
  # filtering by name/status and shows actions by role, and the server doesn't know who is looking
  # at what. Nor is it a page refresh: with many apps that kept the page reloading non-stop. The
  # page's live-refresh controller fetches its own URL in the background and morphs its regions.
  test "signals the overview after polling, without a rendered grid or a page refresh" do
    FakeHost.seed_container(node: "node-1", service: "blog", role: "web",
                            destination: "production", version: "aaaaaaa")
    FakeHost.proxy_deploy(node: "node-1", service: "blog-web-production",
                          target: "blog-web-production-aaaaaaa:80")

    app = build_app

    assert_broadcasts(OverviewSignal::STREAM, 1) { PollManagedAppJob.perform_now(app) }

    message = ActiveSupport::JSON.decode(broadcasts(OverviewSignal::STREAM).last)
    assert_includes message, 'action="live_refresh"'
    assert_includes message, %(target="#{OverviewSignal::TARGET}")
    refute_includes message, 'action="refresh"', "A whole-page refresh per polling round keeps the overview reloading"
    refute_includes message, 'target="overview-grid"',
      "The server must not render the grid for anyone; it does not know what they are filtering"
  end

  private
    def with_stubbed_method(receiver, method_name, replacement)
      original = receiver.method(method_name)
      receiver.define_singleton_method(method_name, &replacement)
      yield
    ensure
      receiver.define_singleton_method(method_name, original)
    end
end
