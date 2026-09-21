require 'rufus/scheduler'
require 'fugit'

module RedmineAgent
  # Once-a-minute cron tick over CustomAgents.all (agents that have a
  # 'cron' set). Runs in-process with the Rails web server — started once from
  # init.rb's after_initialize hook.
  class Scheduler
    # How late an occurrence may still be claimed: one tick's slack, so a tick
    # that fires late still lands it. A missed occurrence is not backfilled.
    TICK_GRACE = 2 * 60

    # Includes historical retry stamps so clearing old logs remains safe.
    # Only a stamp like this can be derived again, so only these have to
    # outlive a cleared log.
    OCCURRENCE_STAMP = /@\d{4}-\d{2}-\d{2} \d{2}:\d{2}( retry)?\z/.freeze

    # How long a claimed run may sit at 'started' before it counts as
    # interrupted — well past the Runner's 5s open + 300s read timeout.
    STALE_CLAIM_AFTER = 15 * 60

    class << self
      def start!
        # Per process, not per boot: a Puma worker forks after this ran in the
        # parent, and it inherits the flag but none of the threads.
        return if @started_pid == Process.pid
        return if non_server_process?

        scheduler = Rufus::Scheduler.new
        scheduler.cron('* * * * *') { tick }
        @scheduler = scheduler
        @started_pid = Process.pid
        Rails.logger.info 'RedmineAgent::Scheduler started.'
      rescue StandardError => e
        # Only clean up this attempt, not a scheduler inherited after a fork.
        @scheduler = nil
        @started_pid = nil
        begin
          scheduler&.shutdown
        rescue StandardError => cleanup_error
          Rails.logger.warn "RedmineAgent::Scheduler cleanup failed: #{cleanup_error.class}: #{cleanup_error.message}"
        end
        Rails.logger.warn "RedmineAgent::Scheduler startup failed: #{e.class}: #{e.message}"
      end

      def tick
        Rails.application.executor.wrap { run_due_agents }
      rescue => e
        Rails.logger.warn "RedmineAgent::Scheduler tick failed: #{e.class}: #{e.message}"
      end

      private

      # Works off the last scheduled occurrence rather than the current
      # minute, so a tick that fires a second or two late still runs the job,
      # once. Anything older than TICK_GRACE is gone, not deferred.
      def run_due_agents
        Setting.check_cache
        now = Time.now
        # Show interrupted runs in history for the creator to review.
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
          next if now - due > TICK_GRACE
          # An occurrence older than the schedule itself was never due.
          next if agent['schedule_changed_at'] && due < agent['schedule_changed_at']

          # Stamping the occurrence, not the tick, is what makes it run
          # exactly once: a second worker — or the next tick, still inside the
          # grace — derives the same stamp and loses the claim.
          stamp = claimable_stamp("#{agent['key']}@#{due.utc.strftime('%Y-%m-%d %H:%M')}")
          next unless stamp
          next unless RedmineAgent::Runner.reachable?
          # Claiming the slot IS the dedupe — a unique index, so only one
          # process/thread can win it.
          next unless CustomAgents.claim_run(agent['key'], stamp)

          RedmineAgent::Runner.run_async(agent, stamp)
        rescue StandardError => e
          # One broken agent must not prevent the rest of this tick from running.
          # Keep any existing claim: dispatch may have started before raising.
          Rails.logger.warn "RedmineAgent::Scheduler agent #{agent['key']} failed: #{e.class}: #{e.message}"
        end
      end

      # Each occurrence gets one attempt, regardless of its outcome. The creator
      # can rerun a failed task manually using Run Now (a separate stamp).
      def claimable_stamp(stamp)
        AiAgentRun.exists?(stamp: stamp) ? nil : stamp
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
