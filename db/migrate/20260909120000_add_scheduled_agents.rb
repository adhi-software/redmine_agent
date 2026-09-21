class AddScheduledAgents < ActiveRecord::Migration[8.1]
  AGENT_KEY = 'query'.freeze
  AGENT_NAME = 'Chat'.freeze
  # The name the v1.0.1 app gave the same row, before agents had keys.
  OLD_AGENT_NAME = 'Query Agent'.freeze

  def up
    create_table :ai_agent_runs do |t|
      t.references :ai_agent, null: false, foreign_key: true
      # Unique so two app processes can never both claim the same minute for
      # the same agent — the DB rejects the second INSERT. Never NULL: a
      # SQL Server unique index allows only one of those.
      t.string   :stamp, null: false
      t.string   :status
      t.text     :reply_excerpt
      t.text     :error
      t.datetime :finished_at
      t.datetime :started_at
      t.timestamps
    end
    add_index :ai_agent_runs, :stamp, unique: true
    add_index :ai_agent_runs, [:ai_agent_id, :started_at]

    add_column :ai_agents, :agent_key,     :string
    add_column :ai_agents, :task,          :text
    add_column :ai_agents, :cron,          :string
    add_column :ai_agents, :schedule_changed_at, :datetime
    add_column :ai_agents, :created_by_id, :integer
    # Legacy rows may have no key. SQL Server needs a filtered index to allow
    # several NULLs; the other supported adapters allow them in a unique index.
    key_index_options = { unique: true }
    key_index_options[:where] = 'agent_key IS NOT NULL' if connection.adapter_name == 'SQLServer'
    add_index :ai_agents, :agent_key, **key_index_options

    AiAgent.reset_column_information
    seed_default_agent
  end

  def down
    remove_index :ai_agents, :agent_key
    remove_columns :ai_agents, :agent_key, :task, :cron, :schedule_changed_at, :created_by_id
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
