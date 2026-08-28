module RedmineAgent
  # Delivers over Redmine core's own Mailer (SMTP config, from-address, per-
  # user locale come for free). Never raises — callers get {ok:, error:} back.
  class EmailNotifier
    class << self
      def subject_prefix
        Setting.plugin_redmine_agent['email_subject_prefix'].to_s.presence || '[Redmine Agent]'
      end

      # Redmine falls back to config/environment SMTP defaults with no
      # config/configuration.yml present, which reliably fails — so require
      # that file's email_delivery section before claiming this is usable.
      def configured?
        Redmine::Configuration['email_delivery'].present? && Setting.mail_from.present?
      end

      def deliver(user:, subject:, text:)
        return { ok: false, error: 'not_configured' } unless configured?
        return { ok: false, error: 'no_user' } unless user

        raise_was = AgentMailer.raise_delivery_errors
        AgentMailer.raise_delivery_errors = true
        AgentMailer.agent_message(user, "#{subject_prefix} #{subject}", text).deliver_now
        Rails.logger.info "RedmineAgent: emailed #{user.mail} (#{subject})"
        { ok: true, error: nil }
      rescue => e
        Rails.logger.warn "RedmineAgent email delivery failed: #{e.class}: #{e.message}"
        { ok: false, error: e.message.to_s.truncate(120) }
      ensure
        AgentMailer.raise_delivery_errors = raise_was
      end
    end
  end
end
