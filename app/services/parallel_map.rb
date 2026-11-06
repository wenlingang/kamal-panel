# Runs a block over items on a small, bounded pool of threads and returns the results in input
# order. Exceptions are returned in place, not raised, so one bad item can't sink the others.
#
# Callers use it for slow remote calls (Git platform, registry, one SSH session per host). The block
# must not touch the database: resolve records, associations and decrypted secrets on the calling
# thread first. Each worker is wrapped in the Rails executor so autoloading stays safe.
module ParallelMap
  module_function

  def call(items, threads: 8, &block)
    items = items.to_a
    return [] if items.empty?

    results = Array.new(items.size)
    queue = Queue.new
    items.each_with_index { |item, index| queue << [ item, index ] }

    workers = Array.new([ threads, items.size ].min) do
      Thread.new do
        Rails.application.executor.wrap do
          loop do
            item, index = queue.pop(true)
            results[index] = begin
              block.call(item)
            rescue StandardError => e
              e
            end
          end
        rescue ThreadError
          # queue drained
        end
      end
    end

    # Let the workers load constants while this thread waits, instead of deadlocking on the
    # autoload interlock in development.
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { workers.each(&:join) }
    results
  end
end
