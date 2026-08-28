module RedmineAgent
  # Delivers a message to a list of {user_id, login, mail} recipients over one
  # or more channels, re-validating every recipient against the DB first — the
  # payload (originally the LLM's) is never trusted as-is.
  module Delivery
    class << self
      # slack_channel set routes Slack to one channel post instead of a DM each.
      def deliver_validated(recipients, message, channels: ['slack'], subject: nil, slack_channel: nil)
        entries = Array(recipients).first(50).map do |r|
          uid   = (r['user_id'] || r[:user_id]).to_i
          login = (r['login'] || r[:login]).to_s
          mail  = (r['mail'] || r[:mail]).to_s
          user  = User.active.find_by(id: uid)
          matched = user && user.login == login && user.mail.to_s.casecmp?(mail)
          { uid: uid, login: login, user: matched ? user : nil }
        end

        if slack_channel.present? && channels.include?('slack')
          return deliver_to_channel(entries, message, slack_channel,
                                    also: channels - ['slack'], subject: subject)
        end

        entries.map do |e|
          next mismatch(e) unless e[:user]

          deliver_to(e[:user], message, channels: channels, subject: subject)
        end
      end

      # One channel post @-mentioning everyone. A recipient with no Slack
      # account is named in plain text, so the post still reads correctly.
      def deliver_to_channel(entries, message, channel, also: [], subject: nil)
        valid = entries.select { |e| e[:user] }
        return entries.map { |e| mismatch(e) } if valid.empty?

        slack_ids = valid.to_h { |e| [e[:uid], SlackNotifier.user_id_for(mail: e[:user].mail)] }
        names = valid.map { |e| (id = slack_ids[e[:uid]]) ? SlackNotifier.mention(id) : e[:user].name }
        posted = SlackNotifier.post_channel(channel: channel, text: "#{names.join(' ')}\n\n#{message}")

        entries.map do |e|
          next mismatch(e) unless e[:user]

          sent = { 'slack' => channel_status(posted, slack_ids[e[:uid]]) }
          sent.merge!(deliver_to(e[:user], message, channels: also, subject: subject)[:channels]) if also.any?

          { user_id: e[:uid], login: e[:login], status: status_for(sent.values), channels: sent }
        end
      end

      def mismatch(entry)
        { user_id: entry[:uid], login: entry[:login], status: 'mismatch', channels: {} }
      end

      def channel_status(posted, slack_id)
        return posted[:error].presence || 'failed' unless posted[:ok]

        slack_id ? 'mentioned' : 'no_slack_user'
      end

      def admin_summary(title, message, results, to_user, channels: ['slack'])
        lines = results.map { |r| "#{r[:login]}: #{r[:status]}" }
        text = "#{title}\n\n#{message}\n\n---\n#{lines.join("\n")}"
        result = deliver_to(to_user, text, channels: channels, subject: title)
        { ok: result[:status] != 'failed' }
      end

      def deliver_to(user, message, channels:, subject: nil)
        sent = {}
        channels.each do |ch|
          result =
            case ch
            when 'slack' then SlackNotifier.deliver(mail: user.mail, text: message)
            when 'email' then EmailNotifier.deliver(user: user, subject: subject || 'Notification', text: message)
            else next
            end
          sent[ch] = result[:ok] ? 'sent' : (result[:error].presence || 'failed')
        end

        { user_id: user.id, login: user.login, status: status_for(sent.values), channels: sent }
      end

      # 'mentioned' counts as delivered; 'no_slack_user' does not — that person
      # was named in the post but never actually pinged.
      DELIVERED = %w[sent mentioned].freeze

      def status_for(statuses)
        delivered = statuses.count { |s| DELIVERED.include?(s) }
        return 'failed' if statuses.empty? || delivered.zero?

        delivered == statuses.size ? 'sent' : 'sent_partial'
      end
    end
  end
end
