require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  # Both credential forms submit credential[value] / registry_credential[value]. Rails filters
  # parameters by substring match on the name, and when :value isn't on the list nothing matches
  # "value" -- POST /credentials and PATCH /credentials/:id would write the whole SSH private key
  # and the whole registry password into the production log in plaintext (production logs to STDOUT,
  # i.e. straight into the container logs). This has regressed for real before: back when the
  # credential was still called ssh_private_key it was filtered, and after renaming it to value the
  # list wasn't updated.
  #
  # What's asserted is [behavior], not the shape of the config.filter_parameters array: once the app
  # is fully booted Rails compiles the symbols in the list into a Regexp, so the array no longer
  # contains the symbol :value. An assertion like `assert_includes ..., :value` is green when this
  # file runs alone and red in the full suite -- what it actually guards is execution order, not
  # "the private key won't end up in the log".
  test "凭据表单提交的密文在日志里被遮蔽，而不是留下明文" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    filtered = filter.filter("credential" => { "name" => "生产集群", "value" => "-----BEGIN OPENSSH PRIVATE KEY-----" })
    assert_equal "[FILTERED]", filtered["credential"]["value"]
    assert_equal "生产集群", filtered["credential"]["name"], "只该遮蔽密文，不该把整个表单糊掉"

    filtered = filter.filter("registry_credential" => { "name" => "Docker Hub", "value" => "s3cr3t" })
    assert_equal "[FILTERED]", filtered["registry_credential"]["value"]
    assert_equal "Docker Hub", filtered["registry_credential"]["name"]
  end
end
