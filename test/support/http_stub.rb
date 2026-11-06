require "json"

# Canned HTTP for anything that goes through OutboundHttp (Git providers, RegistryProbe). There is
# no WebMock here; OutboundHttp.adapter is the seam just above Net::HTTP, so the code under test
# still builds real Net::HTTP requests (method, path, headers) and gets real Net::HTTPResponse
# objects back. An unexpected request fails the test rather than reaching the network.
#
#   stub_http("GET https://api.github.com/user" => [ 200, { login: "me" } ]) do |calls|
#     ...
#   end
#
# Keys are "METHOD url" strings or Regexps matched against that string. Values are
# [status, body, headers] or a proc taking the Net::HTTPRequest and returning one.
module HttpStub
  def stub_http(routes)
    calls = []
    lock = Mutex.new
    OutboundHttp.adapter = lambda do |uri, request, _timeout|
      key = "#{request.method} #{uri}"
      lock.synchronize { calls << { key: key, headers: request.to_hash.transform_values(&:first), body: request.body } }

      spec = routes[key] || routes.find { |pattern, _| pattern.is_a?(Regexp) && pattern.match?(key) }&.last
      raise "unstubbed request: #{key}" if spec.nil?

      spec = spec.call(request) if spec.respond_to?(:call)
      raise spec if spec.is_a?(Exception) || (spec.is_a?(Class) && spec < Exception)

      fake_response(*spec)
    end
    yield calls
  ensure
    OutboundHttp.adapter = nil
  end

  def fake_response(status, body = nil, headers = {})
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s, Net::HTTPResponse)
    response = klass.new("1.1", status.to_s, "")
    headers.each { |name, value| response[name] = value }
    body = body.to_json unless body.nil? || body.is_a?(String)
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end
end

ActiveSupport.on_load(:active_support_test_case) { include HttpStub }
ActiveSupport.on_load(:action_dispatch_integration_test) { include HttpStub }
