require 'securerandom'

module RedmineAgent
  # Agent store, backed by Setting.plugin_redmine_agent ('custom_agents').
  # Run history is separate — see the agent_runs table / AgentRun, which is
  # written on every run. Every write here goes through #mutate: a
  # process-level Mutex plus a
  # Setting.check_cache re-read inside the lock, so two threads (an admin
  # request and the scheduler tick) never clobber each other's write.
  #
  # A schedule is just an optional property of an agent (a 'cron' string) —
  # there is no separate schedule store. "Query Agent" is a seeded agent like
  # any other (key 'query_agent', no task, no cron).
  module CustomAgents
    MUTEX = Mutex.new
    SYNC_MUTEX = Mutex.new

    # ":ai_agent_#{key}" must equal the menu item name already class-level
    # registered as the controller's default (menu_item :ai_agent_query).
    QUERY_AGENT_KEY = 'query'.freeze

    # Runs kept per agent.
    MAX_RUNS_PER_AGENT = 50

    # To have a reminder delivered, add a line to the agent's task naming the
    # Slack channel id, e.g. "Then send that reminder to C01234567 with
    # slack_send_message." Nothing is sent unless the task asks for it.
    CLOCK_IN_PROMPT = <<~PROMPT.freeze
      Find the active employees who have not clocked in today.

      Use the attendance and employee tools to work out who is absent. Then reply
      with one short summary line followed by the absent employees, one per line,
      as "name (login)". Name only people the tools actually returned.

      End with a short, polite reminder to clock in for today.
    PROMPT

    TIMESHEET_PROMPT = <<~PROMPT.freeze
      Find the active users who have not submitted this week's timesheet.

      1. Call list_users with status=1 and limit=100, paging with offset until you have
         every active user. Keep each user's id, login and mail.
      2. Call list_timesheets once with user_id set to those ids joined by commas,
         period_type=1 and period=current_week. Do not pass a status filter. It answers
         one row per user for the current week whose status is Empty, New, Rejected,
         Submitted or Approved.
      3. Anyone whose status is Empty, New or Rejected has not submitted.

      Then reply with one short summary line followed by those people, one per line,
      as "name (login)". Name only people the tools actually returned.

      End with a short, polite reminder to submit this week's timesheet before the
      week closes.
    PROMPT

    # Seeded once on first use.
    BUILT_INS = [
      { 'key' => QUERY_AGENT_KEY, 'name' => 'Query Agent', 'task' => '', 'cron' => nil },
      { 'key' => 'clock_in_reminder', 'name' => 'Clock-in reminder', 'task' => CLOCK_IN_PROMPT,
        'cron' => '0 10 * * 1-5 Asia/Kolkata' },
      { 'key' => 'timesheet_submit_reminder', 'name' => 'Timesheet submit reminder', 'task' => TIMESHEET_PROMPT,
        'cron' => '0 18 * * 5 Asia/Kolkata' }
    ].freeze

    class << self
      def all
        seed!
        Array(Setting.plugin_redmine_agent['custom_agents']).map { |a| normalize(a) }
      end

      def find(key)
        all.find { |a| a['key'] == key.to_s }
      end

      def name_taken?(name, except_key: nil)
        n = name.to_s.strip.downcase
        all.any? { |a| a['key'] != except_key.to_s && a['name'].to_s.strip.downcase == n }
      end

      def create(attrs)
        agent = nil
        mutate do |list|
          key = loop do
            k = "ag_#{SecureRandom.hex(4)}"
            break k unless list.any? { |a| a['key'] == k }
          end
          agent = normalize(attrs).merge(
            'key'        => key,
            'enabled'    => true,
            'created_at' => Time.now.utc.iso8601
          )
          list << agent
        end
        agent
      end

      def update(key, attrs)
        updated = nil
        mutate do |list|
          idx = list.index { |a| a['key'] == key.to_s }
          updated = list[idx] = normalize(list[idx].merge(attrs.transform_keys(&:to_s))) if idx
        end
        updated
      end

      # Takes everything keyed to the agent with it: its chat history (via the
      # AiAgent row) and its run log.
      def delete(key)
        agent = find(key)
        return false unless agent

        mutate { |list| list.reject! { |a| a['key'] == key.to_s } }
        AiAgent.find_by(id: agent['ai_agent_id'])&.destroy if agent['ai_agent_id'].present?
        AgentRun.for_agent(key).delete_all
        true
      end

      def last_run(agent_key)
        AgentRun.for_agent(agent_key).recent_first.first
      end

      # Claims this agent's slot for this minute. The unique index on stamp
      # makes the claim atomic across processes, so two app workers can never
      # both run the same schedule — the loser's INSERT is rejected. Returns
      # nil when the slot is already taken.
      def claim_run(agent_key, stamp)
        AgentRun.create!(agent_key: agent_key, stamp: stamp,
                         status: 'started', started_at: Time.now)
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # Updates the claimed row for this stamp, or inserts one for a manual run.
      def log_run(record)
        attrs = {
          status:        record['status'],
          reply_excerpt: record['reply_excerpt'],
          error:         record['error']
        }.compact

        run = record['stamp'].present? ? AgentRun.find_by(stamp: record['stamp']) : nil
        if run
          run.update(attrs)
        else
          AgentRun.create!(attrs.merge(agent_key: record['key'], stamp: record['stamp'],
                                       started_at: record['started_at'] || Time.now))
        end
        prune_runs(record['key'])
        record
      rescue => e
        Rails.logger.warn "RedmineAgent: failed to log run for #{record['key']}: #{e.message}"
        record
      end

      # Find-or-create the AiAgent row this agent's chat history is scoped to,
      # persisting the id back onto the agent record.
      def ai_agent_record(agent)
        if agent['ai_agent_id'].present? && (rec = AiAgent.find_by(id: agent['ai_agent_id']))
          return rec
        end

        rec = AiAgent.named(agent['name']).first
        rec ||= begin
          AiAgent.create!(name: agent['name'], description: agent['task'].to_s.truncate(255))
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
          AiAgent.named(agent['name']).first ||
            AiAgent.create!(name: "#{agent['name']} (#{agent['key']})", description: agent['task'].to_s.truncate(255))
        end
        update(agent['key'], 'ai_agent_id' => rec.id) if rec
        rec
      end

      # Carries a rename/retask onto the linked AiAgent row — the mobile
      # /redmine_agent/agents list reads the name from there.
      def sync_ai_agent!(agent)
        return unless agent && agent['ai_agent_id'].present?

        rec = AiAgent.find_by(id: agent['ai_agent_id'])
        return unless rec

        attrs = { name: agent['name'], description: agent['task'].to_s.truncate(255) }
        # An orphan row may already hold the name — same fallback as #ai_agent_record.
        rec.update(attrs) || rec.update(attrs.merge(name: "#{agent['name']} (#{agent['key']})"))
        rec
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # Reconciles the registered :ai_agent_* menu items against the current
      # agent list. Cheap no-op when nothing changed (the common case, since
      # this runs on every relevant request so every app worker stays in
      # sync without a restart).
      def sync_menu!
        desired = all.map { |a| [a['key'], a['name'].to_s] }
        return if desired == @menu_signature

        SYNC_MUTEX.synchronize do
          return if desired == @menu_signature

          mapper = Redmine::MenuManager.map(:agent_menu)
          present = mapper.menu_items.children.map(&:name).select { |n| n.to_s.start_with?('ai_agent_') }
          wanted = desired.map { |k, _| :"ai_agent_#{k}" }
          (present - wanted).each { |n| mapper.delete(n) }
          desired.each do |k, name|
            mapper.push(:"ai_agent_#{k}",
                        { controller: 'redmine_agent', action: 'index', agent_key: k },
                        caption: name, if: Proc.new { User.current.logged? })
          end
          @menu_signature = desired
        end
      rescue => e
        Rails.logger.warn "RedmineAgent menu sync failed: #{e.class}: #{e.message}"
      end

      private

      # Drops this agent's oldest runs — the log is a rolling window, not an archive.
      def prune_runs(agent_key)
        stale = AgentRun.for_agent(agent_key).recent_first.offset(MAX_RUNS_PER_AGENT).pluck(:id)
        AgentRun.where(id: stale).delete_all if stale.any?
      end

      def normalize(attrs)
        attrs.transform_keys(&:to_s).except('notify')
      end

      def mutate(list_key: 'custom_agents')
        MUTEX.synchronize do
          Setting.check_cache
          s = Setting.plugin_redmine_agent.deep_dup
          list = Array(s[list_key]).dup
          yield list
          s[list_key] = list
          Setting.plugin_redmine_agent = s
        end
      end

      def seed!
        return if Setting.plugin_redmine_agent['custom_agents_seeded'].to_s == '1'
        MUTEX.synchronize do
          Setting.check_cache
          s = Setting.plugin_redmine_agent.deep_dup
          next if s['custom_agents_seeded'].to_s == '1'

          seeded = BUILT_INS.map { |b| b.merge('enabled' => true, 'created_at' => Time.now.utc.iso8601) }
          s['custom_agents'] = seeded + Array(s['custom_agents'])
          s['custom_agents_seeded'] = '1'
          Setting.plugin_redmine_agent = s
        end
      end
    end
  end
end
