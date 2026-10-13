module RedmineAgent
  # The app calling itself — the scheduler's loopback chat and the built-in MCP
  # server. Setting.host_name carries the path too, so a subdirectory install
  # resolves correctly.
  module AppUrl
    def self.base
      "#{Setting.protocol}://#{Setting.host_name}".chomp('/')
    end
  end
end
