module GitProviders
  # The single failure callers handle: they show the message ("Git 平台暂时不可用：…") and fall back
  # to manual version entry. The message is translated when read, not when raised: providers may
  # run on worker threads, where the request's locale isn't set.
  class Error < StandardError
    attr_reader :key, :args

    def initialize(key, **args)
      @key = key
      @args = args
      super("git provider error: #{key} #{args}")
    end

    def message = I18n.t("git_providers.errors.#{key}", **args)
  end
end
