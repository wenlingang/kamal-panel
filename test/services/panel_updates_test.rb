require "test_helper"

class PanelUpdatesTest < ActiveSupport::TestCase
  include HttpStub

  setup { Rails.cache.clear }

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  test "picks the newest vX.Y.Z tag and offers it when newer than the running version" do
    with_env("PANEL_VERSION" => "1.2.0") do
      stub_http(%r{\AGET https://api\.github\.com/repos/wenlingang/kamal-panel/tags} =>
                  [ 200, [ { name: "v1.10.0" }, { name: "v1.9.3" }, { name: "nightly" } ] ]) do
        PanelUpdates.check!
      end

      assert_equal "1.10.0", PanelUpdates.available
    end

    with_env("PANEL_VERSION" => "1.10.0") { assert_nil PanelUpdates.available }
  end

  test "a local build, or the check switched off, never calls out" do
    with_env("PANEL_VERSION" => "dev") do
      stub_http({}) { |calls| PanelUpdates.check!; assert_empty calls }
    end
    with_env("PANEL_VERSION" => "1.0.0", "PANEL_UPDATE_CHECK" => "false") do
      stub_http({}) { |calls| PanelUpdates.check!; assert_empty calls }
    end
  end
end
