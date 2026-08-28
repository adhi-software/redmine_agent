require 'rufus/scheduler'
require 'fugit'

module RedmineAgent
  # Once-a-minute cron tick over CustomAgents.enabled (agents that have a
  # 'cron' set). Runs in-process with the Rails web server — started once from
  # init.rb's after_initialize hook.
  class Scheduler
    class << self
      def start!
        return if @started
        return if non_server_process?

        @started = true
        @scheduler = Rufus::Scheduler.new
        @scheduler.cron('* * * * *') { tick }
        Rails.logger.info 'RedmineAgent::Scheduler started.'
      end

      def tick
        Rails.application.executor.wrap { run_due_agents }
      rescue => e
        Rails.logger.warn "RedmineAgent::Scheduler tick failed: #{e.class}: #{e.message}"
      end

      private

      def run_due_agents
        Setting.check_cache
        # A 5-field cron requires an exact 0-second match, but this tick can
        # itself fire a little after :00 — truncate to the start of the
        # current minute so a late tick still matches.
        now = Time.at((Time.now.to_i / 60) * 60)
        minute = now.strftime('%Y-%m-%d %H:%M')

        CustomAgents.enabled.each do |agent|
          next if agent['cron'].blank?

          cron = Fugit::Cron.parse(agent['cron'])
          next unless cron

          # The cron's own timezone is what's compared against, so a schedule
          # saved in Asia/Kolkata fires at the right wall-clock time
          # regardless of the server's local zone.
          next unless cron.match?(now)

          stamp = "#{agent['key']}@#{minute}"
          next unless RedmineAgent::Runner.reachable?
          # Claiming the slot IS the dedupe — a unique index, so only one
          # process/thread can win it for this minute.
          next unless CustomAgents.claim_run(agent['key'], stamp)

          Thread.new { RedmineAgent::Runner.run(agent, stamp) }
        end
      end

      # A `rails runner`/`rails console`/`rails test`/`rake` process fully
      # boots the app (triggering this same after_initialize hook) with no web
      # server behind it. A scheduler started there would steal a tick the
      # real server should have run, and any loopback HTTP call would fail
      # with ECONNREFUSED. Runner.reachable? is a second line of defense.
      def non_server_process?
        return false if ENV['AGENT_SCHEDULER'] == 'force'

        defined?(Rails::Console) ||
          defined?(Rails::Command::RunnerCommand) ||
          defined?(Rails::Command::TestCommand) ||
          defined?(Rails::Command::DbconsoleCommand) ||
          File.basename($PROGRAM_NAME) == 'rake'
      end
    end
  end
end
