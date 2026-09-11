require 'securerandom'

module RedmineAgent
  # Agent store, backed by the ai_agents table — one row per agent, identified
  # by its agent_key. Run history is separate: see the ai_agent_runs table /
  # AiAgentRun, which is written on every run.
  #
  # Callers work with plain hashes ('key', 'name', 'task', 'cron', ...); the
  # column mapping lives here.
  #
  # A schedule is just an optional property of an agent (a 'cron' string) —
  # there is no separate schedule store. "Chat" is the default agent
  # (key 'query', no task, no cron); it is seeded by the migration.
  module CustomAgents
    SYNC_MUTEX = Mutex.new

    # ":ai_agent_#{key}" must equal the menu item name already class-level
    # registered as the controller's default (menu_item :ai_agent_query).
    QUERY_AGENT_KEY = 'query'.freeze

    # Runs kept per agent.
    MAX_RUNS_PER_AGENT = 50

    # A claim the user cleared: kept so the occurrence is not re-run, shown
    # nowhere, never retried (the Scheduler only retries 'error').
    CLEARED_STATUS = 'cleared'.freeze

    # A failure we cannot prove left nothing behind: shown like any other
    # error, but never retried — the work may already have happened.
    PARTIAL_ERROR_STATUS = 'error_partial'.freeze

    class << self
      # Every agent, whoever owns it — the scheduler runs them all.
      # What the scheduler ticks over: an inactive agent is switched off.
      def all
        AiAgent.agents.active.order(:id).map { |record| to_hash(record) }
      end

      # The agents this user may see: their own, plus the shared default agent.
      def visible_to(user)
        AiAgent.visible(user).order(:id).map { |record| to_hash(record) }
      end

      # Takes the two columns rather than an agent hash: the menu's condition
      # runs on every request, from a signature that holds just these.
      def visible?(key, created_by, user = User.current)
        return false unless user.logged?

        key.to_s == QUERY_AGENT_KEY || (created_by.present? && created_by == user.id)
      end

      def find(key)
        record = record_for(key)
        record && to_hash(record)
      end

      # The AiAgent row an agent's chat history is scoped to.
      def ai_agent_record(agent)
        record_for(agent.is_a?(Hash) ? agent['key'] : agent)
      end

      def record_for(key)
        k = key.to_s
        k.present? ? AiAgent.find_by(agent_key: k) : nil
      end

      # Mirrors the unique name column: excluded by id, so the check does not
      # depend on how the database compares a NULL agent_key.
      def name_taken?(name, except_key: nil)
        scope = AiAgent.named(name)
        current = except_key.present? ? record_for(except_key) : nil
        scope = scope.where.not(id: current.id) if current
        scope.exists?
      end

      def create(attrs)
        attrs = attrs.transform_keys(&:to_s)
        key = loop do
          k = "ag_#{SecureRandom.hex(4)}"
          break k unless AiAgent.exists?(agent_key: k)
        end

        record = AiAgent.new(column_attrs(attrs).merge(agent_key: key))
        record.save!
        to_hash(record)
      end

      def update(key, attrs)
        record = record_for(key)
        return nil unless record

        was, cron_was = record.updated_at, record.cron
        record.update!(column_attrs(attrs.transform_keys(&:to_s)))
        # The scheduler reads updated_at as when the schedule was set, so an
        # edit that leaves the cron alone must not re-arm that guard.
        record.update_column(:updated_at, was) if was && record.cron == cron_was
        to_hash(record)
      end

      # Takes everything keyed to the agent with it: its chat history (rows
      # cascade off the AiAgent) and its run log.
      def delete(key)
        record = record_for(key)
        return false unless record

        record.destroy
        AiAgentRun.for_agent(key).delete_all
        true
      end

      # The page shows failed runs, so clearing the history clears the log too.
      # A claim the scheduler could still re-derive is blanked instead of
      # deleted: deleting it hands the occurrence back to the next tick.
      def clear_runs(agent_key)
        scope = AiAgentRun.for_agent(agent_key)
        scope.where.not(id: live_claim_ids(scope)).delete_all
        scope.update_all(status: CLEARED_STATUS, error: nil, reply_excerpt: nil)
      end

      # Everything kept for this agent — prune_runs already caps the window.
      def runs(agent_key)
        AiAgentRun.for_agent(agent_key).recent_first.limit(MAX_RUNS_PER_AGENT)
      end

      # Claims this agent's slot for this minute. The unique index on stamp
      # makes the claim atomic across processes, so two app workers can never
      # both run the same schedule — the loser's INSERT is rejected. Returns
      # nil when the slot is already taken.
      def claim_run(agent_key, stamp)
        AiAgentRun.create!(agent_key: agent_key, stamp: stamp,
                         status: 'started', started_at: Time.now)
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # A claim whose process died mid-run: nothing else ever moves it off
      # 'started'. Whether it wrote anything first is unknowable, so it is shown
      # but not retried.
      def fail_stale_runs(cutoff)
        AiAgentRun.where(status: 'started')
                  .where('started_at < ?', cutoff)
                  .update_all(status: PARTIAL_ERROR_STATUS, error: 'run interrupted')
      end

      # Updates the claimed row for this stamp, or inserts one for a manual run.
      def log_run(record)
        attrs = {
          status:        record['status'],
          reply_excerpt: record['reply_excerpt'],
          error:         record['error']
        }.compact

        run = record['stamp'].present? ? AiAgentRun.find_by(stamp: record['stamp']) : nil
        if run
          run.update(attrs)
        else
          AiAgentRun.create!(attrs.merge(agent_key: record['key'], stamp: record['stamp'],
                                       started_at: record['started_at'] || Time.now))
        end
        prune_runs(record['key'])
        record
      rescue => e
        Rails.logger.warn "RedmineAgent: failed to log run for #{record['key']}: #{e.message}"
        record
      end

      # Reconciles the registered :ai_agent_* menu items against the current
      # agent list. Cheap no-op when nothing changed (the common case, since
      # this runs on every relevant request so every app worker stays in
      # sync without a restart).
      def sync_menu!
        desired = AiAgent.agents.order(:id).pluck(:agent_key, :name, :created_by_id)
        return if desired == @menu_signature

        SYNC_MUTEX.synchronize do
          return if desired == @menu_signature

          mapper = Redmine::MenuManager.map(:agent_menu)
          present = mapper.menu_items.children.map(&:name).select { |n| n.to_s.start_with?('ai_agent_') }
          wanted = desired.map { |k, _| :"ai_agent_#{k}" }
          (present - wanted).each { |n| mapper.delete(n) }
          desired.each do |k, name, created_by|
            mapper.push(:"ai_agent_#{k}",
                        { controller: 'redmine_agent', action: 'index', agent_key: k },
                        # Registration is process-wide; this runs per request,
                        # so each user sees only the agents that are theirs.
                        caption: name, if: Proc.new { visible?(k, created_by) })
          end
          @menu_signature = desired
        end
      rescue => e
        Rails.logger.warn "RedmineAgent menu sync failed: #{e.class}: #{e.message}"
      end

      private

      # Drops this agent's oldest runs — the log is a rolling window, not an
      # archive. A live claim is never dropped, however old the row is.
      def prune_runs(agent_key)
        scope = AiAgentRun.for_agent(agent_key)
        stale = scope.recent_first.offset(MAX_RUNS_PER_AGENT).pluck(:id) - live_claim_ids(scope)
        AiAgentRun.where(id: stale).delete_all if stale.any?
      end

      # Claims a tick could still re-derive, so deleting one re-runs it. A
      # manual run's stamp is unique per click and never comes back.
      def live_claim_ids(scope)
        cutoff = Time.now - RedmineAgent::Scheduler::CATCHUP_WINDOW
        scope.where('started_at >= ?', cutoff).pluck(:id, :stamp)
             .select { |_id, stamp| stamp.to_s.match?(RedmineAgent::Scheduler::OCCURRENCE_STAMP) }
             .map(&:first)
      end

      def to_hash(record)
        {
          'key'         => record.agent_key,
          'name'        => record.name,
          'task'        => record.task.to_s,
          'cron'        => record.cron.presence,
          'created_by'  => record.created_by_id,
          'created_at'  => record.created_at&.utc&.iso8601,
          # A Time, not a string: the scheduler compares it against an
          # occurrence to ignore ones that predate the schedule.
          'updated_at'  => record.updated_at,
          'ai_agent_id' => record.id
        }
      end

      # Only the keys actually given are mapped, so a partial update never
      # blanks a field it was not asked about.
      def column_attrs(attrs)
        out = {}
        out[:name] = attrs['name'].to_s.strip if attrs.key?('name')
        out[:cron] = attrs['cron'].presence   if attrs.key?('cron')
        out[:created_by_id] = attrs['created_by'] if attrs.key?('created_by')
        if attrs.key?('task')
          out[:task] = attrs['task'].to_s
          # The mobile agent list reads the description, not the task.
          out[:description] = attrs['task'].to_s.truncate(255)
        end
        out
      end
    end
  end
end
