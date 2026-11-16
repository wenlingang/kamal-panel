require "test_helper"

class BackupRunnerTest < ActiveSupport::TestCase
  include HttpStub

  # Stands in for the SSH session: yields a canned dump and answers with an exit status.
  class FakeSession
    attr_reader :commands

    def initialize(chunks: [], status: 0, stderr: "", raises: nil)
      @chunks, @status, @stderr, @raises = chunks, status, stderr, raises
      @commands = []
    end

    def stream(host, command, timeout:)
      raise @raises if @raises

      @commands << [ host, command ]
      @chunks.each { |chunk| yield chunk }
      { status: @status, stderr: @stderr }
    end
  end

  setup do
    @app = ManagedApp.create!(name: "blog", config_yaml: file_fixture("accessory_deploy.yml").read, destination: "production")
    @destination = BackupDestination.create!(name: "minio", endpoint: "http://minio.internal:9000", bucket: "backups",
                                             prefix: "panel", access_key_id: "key", secret_access_key: "secret")
    @plan = @app.backup_plans.create!(accessory: "db", engine: "postgres", backup_destination: @destination, keep: 2)
  end

  test "dumps on the accessory's host, gzips, uploads, and keeps only `keep` copies" do
    old = 3.times.map do |i|
      @plan.backup_runs.create!(managed_app: @app, state: "succeeded", object_key: "panel/blog/db/old-#{i}.sql.gz",
                                started_at: (i + 1).days.ago, finished_at: (i + 1).days.ago)
    end
    session = FakeSession.new(chunks: [ "CREATE TABLE posts;\n", "COPY posts FROM stdin;\n" ])

    stub_http(%r{\APUT http://minio\.internal:9000/backups/panel/blog/db/\d{8}T\d{6}Z-\d+\.sql\.gz\z} => [ 200, "" ],
              %r{\ADELETE http://minio\.internal:9000/backups/panel/blog/db/old-} => [ 204, "" ]) do |calls|
      run = BackupRunner.call(@plan, session:)

      assert_predicate run, :succeeded?
      assert_operator run.size_bytes, :>, 0
      assert_equal "10.0.0.3", session.commands.sole.first
      assert_equal 2, calls.count { |call| call[:key].start_with?("DELETE") }, "keep 2: the new one and the newest old one"
    end

    assert_nil old[0].reload.pruned_at
    assert old[1].reload.pruned_at && old[2].reload.pruned_at
  end

  test "a failed dump is recorded with its error and diagnosis, and nothing is uploaded" do
    session = FakeSession.new(status: 1, stderr: "Error response from daemon: No such container: blog-db\nbash: docker: command not found")

    stub_http({}) do |calls|
      run = BackupRunner.call(@plan, session:)

      assert_predicate run, :failed?
      assert_includes run.error, "No such container"
      assert_equal "docker_missing", run.diagnosis["key"]
      assert_empty calls
    end
  end

  test "an unreachable host fails the run instead of raising" do
    run = BackupRunner.call(@plan, session: FakeSession.new(raises: Errno::EHOSTUNREACH))

    assert_predicate run, :failed?
    assert_equal "ssh_unreachable", run.diagnosis["key"]
  end
end
