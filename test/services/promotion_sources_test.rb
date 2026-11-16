require "test_helper"

class PromotionSourcesTest < ActiveSupport::TestCase
  setup do
    yaml = file_fixture("simple_deploy.yml").read
    @production = ManagedApp.create!(name: "blog", config_yaml: yaml, destination: "production")
    @staging = ManagedApp.create!(name: "blog-staging", config_yaml: yaml, destination: "staging")
    @unrelated = ManagedApp.create!(name: "shop", config_yaml: yaml.sub("image: example/blog", "image: example/shop"),
                                    destination: "staging")
  end

  def observe(app, version, health: "healthy")
    at = Time.current
    %w[web worker].each do |role|
      Observation.create!(managed_app: app, host: "127.0.0.1", role:, reachable: true, version:, docker_status: "running",
                          container_name: "blog-#{role}-#{app.destination}-#{version}",
                          health: (role == "web" ? health : nil), observed_at: at)
    end
  end

  test "lists the same image in other destinations, with the version it runs" do
    observe(@staging, "abc1234")

    sources = PromotionSources.new(@production).sources
    assert_equal [ @staging ], sources.map(&:app)
    assert_equal "abc1234", sources.sole.version
    assert_predicate sources.sole, :ready?
  end

  test "won't promote from an environment that isn't settled" do
    assert_equal "no_version", PromotionSources.new(@production).sources.sole.blocker

    observe(@staging, "abc1234", health: "unhealthy")
    assert_equal "unhealthy", PromotionSources.new(@production).sources.sole.blocker
  end
end
