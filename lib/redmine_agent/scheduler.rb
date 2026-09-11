require 'rufus/scheduler'
require 'fugit'

module RedmineAgent
  # Once-a-minute cron tick over CustomAgents.all (agents that have a
  # 'cron' set). Runs in-process with the Rails web server — started once from
  # init.rb's after_initialize hook.
  class Scheduler
    # How late a missed occurrence may still be run. Long enough to cover a
    # restart or a short outage, short enough that a weekend of downtime does
    # not fire Friday's reminder on Monday.
    CATCHUP_WINDOW = 6 * 60 * 60

    # Marks the one retry a failed occurrence gets.
    RETRY_SUFFIX = ' retry'.freeze

    # The stamp shape run_due_agents builds below, RETRY_SUFFIX included.
    # Only a stamp like this can be derived again, so only these have to
    # outlive a cleared log.
    OCCURRENCE_STAMP = /@\d{4}-\d{2}-\d{2} \d{2}:\d{2}( retry)?\z/.freeze

    # How long a claimed run may sit at 'started' before it counts as
    # interrupted — well past the Runner's 5s open + 120s read timeout.
    STALE_CLAIM_AFTER = 15 * 60

    class << self
      def start!
        # Per process, not per boot: a Puma worker forks after this ran in the
        # parent, and it inherits the flag but none of the threads.
        return if @started_pid == Process.pid
        return if non_server_process?

        @started_pid = Process.pid
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

      # Works off the last scheduled occurrence rather than the current
      # minute, so a tick that fires late — or a server that was down when the
      # minute passed — still runs the job, once, if it is back inside
      # CATCHUP_WINDOW.
      def run_due_agents
        Setting.check_cache
        now = Time.now
        # Failing a dead claim here is what makes it visible and retryable.
        CustomAgents.fail_stale_runs(now - STALE_CLAIM_AFTER)

        CustomAgents.all.each do |agent|
          next if agent['cron'].blank?

          cron = Fugit::Cron.parse(agent['cron'])
          next unless cron
          # A run acts as the agent's creator, so a locked or deleted account
          # means it cannot run at all — skipping beats logging the same error
          # on every occurrence forever.
          next unless User.active.exists?(id: agent['created_by'])

          # The cron carries its own timezone, so a schedule saved in
          # Asia/Kolkata resolves to the right wall-clock time whatever the
          # server's zone is.
          due = cron.previous_time(now).to_t
          next if now - due > CATCHUP_WINDOW
          # An occurrence older than the schedule itself was never due.
          next if agent['updated_at'] && due < agent['updated_at']

          # Stamping the occurrence, not the tick, is what makes a catch-up
          # run exactly once: every later tick in the window derives the same
          # stamp and loses the claim.
          stamp = claimable_stamp("#{agent['key']}@#{due.utc.strftime('%Y-%m-%d %H:%M')}")
          next unless stamp
          next unless RedmineAgent::Runner.reachable?
          # Claiming the slot IS the dedupe — a unique index, so only one
          # process/thread can win it.
          next unless CustomAgents.claim_run(agent['key'], stamp)

          RedmineAgent::Runner.run_async(agent, stamp)
        end
      end

      # The stamp to claim for this occurrence, or nil when there is nothing
      # left to do — which is every tick in the window after the run, so the
      # doomed INSERT and the reachability probe are skipped. A run that
      # failed gets one more attempt, under its own stamp so both stay in the
      # history.
      def claimable_stamp(stamp)
        run = AiAgentRun.find_by(stamp: stamp)
        return stamp if run.nil?
        return nil unless run.status == 'error'

        retry_stamp = "#{stamp}#{RETRY_SUFFIX}"
        AiAgentRun.exists?(stamp: retry_stamp) ? nil : retry_stamp
      end

      # A `bin/rails <anything>` process fully boots the app — triggering this same
      # after_initialize hook — with no web server behind it. A scheduler started
      # there steals a tick the real server should have run, then dies with the
      # process. So ask which command is running rather than list every offender:
      # assets:precompile and db:migrate were never on that list. A boot that is not
      # bin/rails at all — puma, Passenger, rackup — defines no Rails::Command and
      # falls through to running. Runner.reachable? is a second line of defense.
      def non_server_process?
        return false if ENV['AGENT_SCHEDULER'] == 'force'
        return false if defined?(Rails::Command::ServerCommand)
        return true  if File.basename($PROGRAM_NAME) == 'rake'

        !!defined?(Rails::Command)
      end
    end
  end
end
