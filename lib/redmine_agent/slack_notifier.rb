require 'net/http'
require 'uri'
require 'json'

module RedmineAgent
  # Sends a 1:1 Slack DM by email lookup, or one post to a channel, using a bot
  # token (not a channel webhook). Never raises — callers get {ok:, error:} back.
  class SlackNotifier
    API = 'https://slack.com/api/'.freeze

    class << self
      def token
        Setting.plugin_redmine_agent['slack_bot_token'].to_s.strip
      end

      def configured?
        token.present?
      end

      def auth_test(override_token = nil)
        call('auth.test', {}, use_token: override_token.presence || token)
      end

      # mail: recipient's email address. text: message body.
      def deliver(mail:, text:)
        return { ok: false, error: 'not_configured' } unless configured?
        return { ok: false, error: 'no_mail' } if mail.to_s.strip.blank?

        user_id = user_id_for(mail: mail)
        return { ok: false, error: 'user_not_found' } if user_id.blank?

        opened = call('conversations.open', { users: user_id })
        return { ok: false, error: opened[:error] || 'dm_open_failed' } unless opened[:ok]

        channel_id = opened.dig(:body, 'channel', 'id')
        posted = call('chat.postMessage', { channel: channel_id, text: text })
        { ok: posted[:ok], error: posted[:error] }
      rescue => e
        Rails.logger.warn "Slack delivery failed: #{e.class}: #{e.message}"
        { ok: false, error: e.message.to_s.truncate(120) }
      end

      # Slack member id for an email address, or nil when there is no match.
      def user_id_for(mail:)
        return nil unless configured?
        return nil if mail.to_s.strip.blank?

        lookup = call('users.lookupByEmail', { email: mail }, get: true)
        lookup[:ok] ? lookup.dig(:body, 'user', 'id').presence : nil
      rescue => e
        Rails.logger.warn "Slack lookup failed for #{mail}: #{e.class}: #{e.message}"
        nil
      end

      # Posts once to a channel ("#name"). The bot needs chat:write.public, or
      # to have been invited — otherwise Slack answers not_in_channel.
      def post_channel(channel:, text:)
        return { ok: false, error: 'not_configured' } unless configured?
        return { ok: false, error: 'no_channel' } if channel.to_s.strip.blank?

        posted = call('chat.postMessage', { channel: channel.to_s.strip, text: text })
        { ok: posted[:ok], error: posted[:error] }
      rescue => e
        Rails.logger.warn "Slack channel post failed: #{e.class}: #{e.message}"
        { ok: false, error: e.message.to_s.truncate(120) }
      end

      # Slack renders this as a real @-mention that pings the member.
      def mention(user_id)
        "<@#{user_id}>"
      end

      private

      def call(method, payload, get: false, use_token: nil, retried: false)
        api_token = use_token.presence || token
        uri = URI.parse("#{API}#{method}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 15

        req =
          if get
            uri.query = URI.encode_www_form(payload)
            Net::HTTP::Get.new(uri.request_uri)
          else
            r = Net::HTTP::Post.new(uri.request_uri)
            r['Content-Type'] = 'application/json'
            r.body = payload.to_json
            r
          end
        req['Authorization'] = "Bearer #{api_token}"

        response = http.request(req)
        body = JSON.parse(response.body) rescue {}

        if !body['ok'] && body['error'] == 'ratelimited' && !retried
          sleep([response['Retry-After'].to_i, 5].min)
          return call(method, payload, get: get, use_token: use_token, retried: true)
        end

        { ok: !!body['ok'], error: body['error'], body: body }
      rescue => e
        Rails.logger.warn "Slack API #{method} failed: #{e.class}: #{e.message}"
        { ok: false, error: e.message.to_s.truncate(120) }
      end
    end
  end
end
