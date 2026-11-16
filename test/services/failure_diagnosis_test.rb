require "test_helper"

class FailureDiagnosisTest < ActiveSupport::TestCase
  def key_for(output) = FailureDiagnosis.call(output)&.fetch("key")

  test "names common kamal failures" do
    {
      "ERROR (SSHKit::Command::Failed): docker stderr: Error: target failed to become healthy within configured timeout (30s)" => "health_check_failed",
      "Deploy lock found. Run 'kamal lock help' for more information" => "deploy_lock",
      "ERROR (Net::SSH::AuthenticationFailed): Authentication failed for user deploy@10.0.0.1" => "ssh_auth",
      "ERROR (Errno::ECONNREFUSED): Connection refused - connect(2) for 10.0.0.1:22" => "ssh_unreachable",
      "Error response from daemon: Head https://ghcr.io/v2/acme/blog/manifests/abc: unauthorized" => "registry_auth",
      "Error response from daemon: manifest for ghcr.io/acme/blog:abc123 not found: manifest unknown" => "image_missing",
      "write /var/lib/docker/tmp: no space left on device" => "disk_full",
      "Bind for 0.0.0.0:5432 failed: port is already allocated" => "port_in_use",
      "bash: docker: command not found" => "docker_missing",
      "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" => "docker_permission",
      "ERROR: failed to solve: failed to compute cache key: \"/config/master.key\": not found" => "build_copy_missing",
      "npm error Missing script: \"build\"" => "build_npm_script",
      "Could not resolve host: github.com" => "network",
      "some output\n[面板] 执行超时，已终止" => "timed_out"
    }.each do |output, expected|
      assert_equal expected, key_for(output), "expected #{expected} for: #{output}"
    end
  end

  test "pulls the named detail out of the output" do
    assert_equal({ "key" => "secret_missing", "args" => { "name" => "DATABASE_URL" } },
                 FailureDiagnosis.call("ERROR (Kamal::ConfigurationError): Secret 'DATABASE_URL' not found in .kamal/secrets"))
    assert_equal "deploy@10.0.0.1", FailureDiagnosis.call("Authentication failed for user deploy@10.0.0.1")["args"]["user"]
  end

  test "nothing recognisable gives no diagnosis" do
    assert_nil FailureDiagnosis.call("everything went sideways in a new way")
    assert_nil FailureDiagnosis.call(nil)
  end

  test "only the tail of a long output is read" do
    early = "no space left on device\n" + ("progress\n" * FailureDiagnosis::TAIL_LINES)
    assert_nil FailureDiagnosis.call(early)
  end

  test "every rule has words in both languages" do
    FailureDiagnosis::KEYS.each do |key|
      %i[en zh-CN].each do |locale|
        explained = FailureDiagnosis.explain({ "key" => key, "args" => {} }, locale:)
        assert explained[:cause].present?, "#{key} has no #{locale} cause"
        assert explained[:fix].present?, "#{key} has no #{locale} fix"
      end
    end
  end

  test "an unknown key explains nothing" do
    assert_nil FailureDiagnosis.explain({ "key" => "from_the_future" })
  end
end
