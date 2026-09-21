require 'net/http'
require 'uri'
require 'json'
require 'socket'

module RedmineAgent
  # Executes one agent's task as a loopback chat request and records the reply
  # as a run-history summary. Anything the task should send goes out as an MCP
  # tool call inside that chat, not from here.
  class Runner
    # A run's own request is the only one allowed to skip the approval gate, so
    # the proof it is one has to be unforgeable by a browser.
    RUN_TOKEN_HEADER = 'X-Redmine-Agent-Run'.freeze
    RUN_TOKEN_TTL    = 300

    # A chat that answered with an error. `executed` is the endpoint's own word
    # on whether a data-changing tool had already run in that turn.
    class RunFailed < StandardError
      attr_reader :executed

      def initialize(message, executed: nil)
        super(message)
        @executed = executed
      end
    end

    class << self
      def token_for(agent_key)
        verifier.generate({ 'key' => agent_key.to_s }, expires_in: RUN_TOKEN_TTL)
      end

      def valid_token?(token, agent_key)
        data = verifier.verified(token.to_s)
        data.is_a?(Hash) && data['key'] == agent_key.to_s
      rescue StandardError
        false
      end

      def reachable?
        uri = URI.parse(base_url)
        port = uri.port || (uri.scheme == 'https' ? 443 : 80)
        Socket.tcp(uri.host, port, connect_timeout: 2) { true }
      rescue StandardError
        false
      end

      # A spawned thread is outside its caller's executor: the wrap is what
      # returns its DB connection and keeps it clear of a dev-mode reload.
      def run_async(agent, stamp)
        Thread.new { Rails.application.executor.wrap { run(agent, stamp) } }
      end

      def run(agent, stamp)
        record = { 'key' => agent['key'], 'stamp' => stamp, 'started_at' => Time.now.utc.iso8601 }

        # A run authenticates with an API key, which core accepts only while the
        # REST web service is on. Saying so beats a bare 401 from the chat endpoint.
        unless Setting.rest_api_enabled?
          record['status'] = 'error'
          record['error']  = I18n.t(:error_agent_rest_api_disabled)
          return CustomAgents.log_run(record)
        end

        # A scheduled run acts as whoever created the agent — its permissions
        # are theirs, so no fallback if that account is gone or locked.
        run_as = User.active.find_by(id: agent['created_by'])
        unless run_as
          record['status'] = 'error'
          record['error']  = 'agent creator not found or locked'
          return CustomAgents.log_run(record)
        end

        response = post_chat(agent['task'], run_as.api_key, agent['key'])
        record['reply_excerpt'] = response['reply'].to_s.truncate(300)
        record['status'] = 'ok'
        CustomAgents.log_run(record)
      rescue => e
        Rails.logger.warn "RedmineAgent::Runner failed for #{agent['key']}: #{e.class}: #{e.message}"
        record ||= { 'key' => agent['key'], 'stamp' => stamp }
        record['status'] = failed_before_execution?(e) ? 'error' : CustomAgents::PARTIAL_ERROR_STATUS
        record['error']  = e.message.to_s.truncate(200)
        CustomAgents.log_run(record)
      end

      # Preserve the distinction between a known clean failure and a failure
      # that may have performed writes, so the creator can review before rerunning.
      def failed_before_execution?(error)
        case error
        when RunFailed then error.executed == false
        when Net::OpenTimeout, SocketError, Errno::ECONNREFUSED then true
        else false
        end
      end

      private

      def verifier
        Rails.application.message_verifier('redmine_agent/runner')
      end

      def base_url
        RedmineAgent::AppUrl.base
      end

      def post_chat(prompt, api_key, agent_key)
        uri = URI.parse("#{base_url}/redmine_agent/chat.json")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 300

        req = Net::HTTP::Post.new(uri.request_uri)
        req['Content-Type']       = 'application/json'
        req['X-Redmine-API-Key']  = api_key.to_s
        # This header skips the approval gate — a run has nobody to ask.
        req[RUN_TOKEN_HEADER]     = token_for(agent_key)
        req.body = { message: prompt, agent_key: agent_key }.to_json

        response = http.request(req)
        body = parse_body(response)
        # A failed chat renders {error: ...} with 502; the caller's rescue is
        # what turns this into an error run.
        unless response.is_a?(Net::HTTPSuccess)
          raise RunFailed.new(body['error'].to_s.presence || "HTTP #{response.code} #{response.message}",
                              executed: body['executed'])
        end
        # A proxy/login page or malformed payload does not prove the task
        # succeeded, or that it is safe to repeat any writes it may have made.
        unless body['reply'].is_a?(String) && !body.key?('error')
          raise RunFailed.new('Invalid chat response: expected a reply string')
        end
        body
      end

      def parse_body(response)
        parsed = JSON.parse(response.body.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
