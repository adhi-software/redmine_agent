class AddScheduledAgents < ActiveRecord::Migration[8.1]
  AGENT_KEY = 'query'.freeze
  AGENT_NAME = 'Chat'.freeze
  # The name the v1.0.1 app gave the same row, before agents had keys.
  OLD_AGENT_NAME = 'Query Agent'.freeze

  def up
    create_table :ai_agent_runs do |t|
      t.string   :agent_key, null: false, index: true
      # Unique so two app processes can never both claim the same minute for
      # the same agent — the DB rejects the second INSERT. Never NULL: a
      # SQL Server unique index allows only one of those.
      t.string   :stamp, null: false
      t.string   :status
      t.text     :reply_excerpt
      t.text     :error
      t.datetime :started_at
      t.timestamps
    end
    add_index :ai_agent_runs, :stamp, unique: true
    add_index :ai_agent_runs, [:agent_key, :started_at]

    add_column :ai_agents, :agent_key,     :string
    add_column :ai_agents, :task,          :text
    add_column :ai_agents, :cron,          :string
    add_column :ai_agents, :created_by_id, :integer
    # Not a unique index: SQL Server allows only one NULL in one, and rows left
    # over from the old two-table split have no key. AiAgent validates it.
    add_index :ai_agents, :agent_key

    AiAgent.reset_column_information
    seed_default_agent
  end

  def down
    remove_index :ai_agents, :agent_key
    remove_columns :ai_agents, :agent_key, :task, :cron, :created_by_id
    drop_table :ai_agent_runs
  end

  private

  # Only the default agent is seeded — every other agent is created from the
  # UI. A row already holding either name is adopted rather than duplicated,
  # so its chat history stays attached.
  def seed_default_agent
    record = AiAgent.find_by(agent_key: AGENT_KEY) ||
             AiAgent.named(AGENT_NAME).first ||
             AiAgent.named(OLD_AGENT_NAME).first ||
             AiAgent.new
    record.assign_attributes(name: AGENT_NAME, agent_key: AGENT_KEY,
                             task: '', cron: nil, description: '')
    record.save!
  end
end
