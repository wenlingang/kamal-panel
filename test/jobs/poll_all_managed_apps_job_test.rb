require "test_helper"

class PollAllManagedAppsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @app = ManagedApp.create!(
      name: "blog-#{SecureRandom.hex(4)}", config_yaml: file_fixture("simple_deploy.yml").read,
      destination: "production"
    )
  end

  test "两次紧挨着的调度只入队一次——认领槽位是原子的" do
    assert_enqueued_jobs 1, only: PollManagedAppJob do
      PollAllManagedAppsJob.perform_now
      PollAllManagedAppsJob.perform_now
    end
  end

  test "真正并发地认领同一个应用的槽位，也只有一个线程能认领成功" do
    job = PollAllManagedAppsJob.new
    thread_count = 20
    start = Queue.new

    threads = thread_count.times.map do
      Thread.new do
        start.pop
        job.send(:claim_slot!, @app)
      end
    end
    thread_count.times { start << true } # 尽量让所有线程同时启动，最大化竞争窗口

    winners = threads.map(&:value).count(true)

    assert_equal 1, winners
  end

  test "认领过期（到了下一个节奏周期）后，调度会重新入队" do
    PollAllManagedAppsJob.perform_now
    assert_enqueued_jobs 1, only: PollManagedAppJob

    travel(PollCadence::IDLE + 1.second) do
      PollAllManagedAppsJob.perform_now
    end

    assert_enqueued_jobs 2, only: PollManagedAppJob
  end

  test "认领槽位被缓存驱逐等价于从没跑过——必须立刻能重新认领，而不是永远认领不到" do
    PollAllManagedAppsJob.perform_now
    assert_enqueued_jobs 1, only: PollManagedAppJob

    Rails.cache.delete(PollCadence.last_run_key(@app)) # 模拟缓存驱逐

    PollAllManagedAppsJob.perform_now
    assert_enqueued_jobs 2, only: PollManagedAppJob
  end

  # setup 里那个应用是活着的，所以这里【不能】断言"一个都没入队"——那样测的
  # 是别的东西。要断言的是：被停用的那一个没有出现在入队的参数里。
  test "停用的应用不再被枚举采集" do
    gone = ManagedApp.create!(name: "gone-#{SecureRandom.hex(4)}",
                              config_yaml: file_fixture("simple_deploy.yml").read,
                              destination: "production")
    gone.deactivate!

    PollAllManagedAppsJob.perform_now

    polled = enqueued_jobs.select { |job| job["job_class"] == "PollManagedAppJob" }
                          .flat_map { |job| job["arguments"] }
                          .filter_map { |arg| arg.is_a?(Hash) ? arg["_aj_globalid"] : nil }

    assert polled.any? { |gid| gid.include?("ManagedApp/#{@app.id}") }, "活着的应用应该照常入队"
    refute polled.any? { |gid| gid.include?("ManagedApp/#{gone.id}") }, "停用的应用不该入队"
  end
end
