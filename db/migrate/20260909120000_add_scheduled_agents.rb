class AddScheduledAgents < ActiveRecord::Migration[8.1]
  AGENT_KEY = 'query'.freeze
  AGENT_NAME = 'Query Agent'.freeze
  AGENT_DESCRIPTION = 'Default Redmine chat agent'.freeze

  def up
    create_table :ai_agent_runs do |t|
      t.references :ai_agent, null: false, foreign_key: true
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
    key_index_options = { unique: true }
    key_index_options[:where] = 'agent_key IS NOT NULL' if connection.adapter_name == 'SQLServer'
    add_index :ai_agents, :agent_key, **key_index_options

    AiAgent.reset_column_information
    seed_default_agent
  end

  def down
    AiAgent.reset_column_information
    default_agent = AiAgent.find_by(agent_key: AGENT_KEY)
    unless default_agent
      raise ActiveRecord::IrreversibleMigration,
            "Cannot preserve the default #{AGENT_NAME} row because agent_key=#{AGENT_KEY.inspect} was not found"
    end

    AiAgent.where.not(id: default_agent.id).find_each(&:destroy!)

    remove_index :ai_agents, :agent_key
    remove_columns :ai_agents, :agent_key, :task, :cron, :schedule_changed_at, :created_by_id
    drop_table :ai_agent_runs
  end

  private

  def seed_default_agent
    record = AiAgent.find_by(agent_key: AGENT_KEY) ||
             AiAgent.named(AGENT_NAME).first
    record ||= AiAgent.new(name: AGENT_NAME, description: AGENT_DESCRIPTION)
    record.assign_attributes(agent_key: AGENT_KEY, task: '', cron: nil)
    record.save!
  end
end
