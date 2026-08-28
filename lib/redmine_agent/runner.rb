require 'net/http'
require 'uri'
require 'json'
require 'socket'

module RedmineAgent
  # Executes one agent's task as a loopback chat request, delivers the reply's
  # notify block, and records both as a run-history summary. Delivery lives
  # here only, so ordinary chat never sends anything.
  class Runner
    class << self
      def reachable?
        uri = URI.parse(base_url)
        port = uri.port || (uri.scheme == 'https' ? 443 : 80)
        Socket.tcp(uri.host, port, connect_timeout: 2) { true }
      rescue StandardError
        false
      end

      def run(agent, stamp = nil)
        record = { 'key' => agent['key'], 'stamp' => stamp, 'started_at' => Time.now.utc.iso8601 }

        run_as = User.active.find_by(login: Setting.plugin_redmine_agent['run_as_login'].to_s.presence || 'admin')
        unless run_as
          record['status'] = 'error'
          record['error']  = 'run_as user not found'
          return CustomAgents.log_run(record)
        end

        response = post_chat(agent['task'], run_as.api_key, agent['key'])
        reply = response['reply'].to_s
        # Delivery outcome goes first so it survives the excerpt truncation.
        record['reply_excerpt'] = [notify!(agent, response['notify']), reply].compact.join("\n").truncate(300)
        record['status'] = 'ok'
        CustomAgents.log_run(record)
      rescue => e
        Rails.logger.warn "RedmineAgent::Runner failed for #{agent['key']}: #{e.class}: #{e.message}"
        record ||= { 'key' => agent['key'], 'stamp' => stamp }
        record['status'] = 'error'
        record['error']  = e.message.to_s.truncate(200)
        CustomAgents.log_run(record)
      end

      private

      # Delivers the chat reply's notify payload over whichever channels the
      # agent has ticked. Returns a one-line summary for the run history, or nil.
      def notify!(agent, payload)
        channels = %w[slack email].select { |c| agent.dig('notify', c) }
        return nil if channels.empty? || payload.blank?

        recipients = Array(payload['recipients'])
        return '[notify: nobody to notify]' if recipients.empty?

        results = Delivery.deliver_validated(
          recipients, payload['message'].to_s,
          channels: channels, subject: agent['name'],
          slack_channel: agent['slack_channel']
        )
        summarize(results, agent['slack_channel'])
      rescue => e
        Rails.logger.warn "RedmineAgent::Runner notify failed for #{agent['key']}: #{e.class}: #{e.message}"
        "[notify error: #{e.message.to_s.truncate(80)}]"
      end

      def summarize(results, channel)
        counts = results.group_by { |r| r[:channels]['slack'] || r[:status] }.transform_values(&:size)
        "[notify #{channel.presence || 'DM'}: " +
          counts.map { |status, n| "#{n} #{status}" }.join(', ') + ']'
      end

      def base_url
        Setting.plugin_redmine_agent['base_url'].to_s.presence || 'http://127.0.0.1:3000'
      end

      def post_chat(prompt, api_key, agent_key)
        uri = URI.parse("#{base_url}/redmine_agent/chat.json")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 120

        req = Net::HTTP::Post.new(uri.request_uri)
        req['Content-Type']       = 'application/json'
        req['X-Redmine-API-Key']  = api_key.to_s
        req.body = { message: prompt, agent_key: agent_key }.to_json

        response = http.request(req)
        JSON.parse(response.body)
      end
    end
  end
end
