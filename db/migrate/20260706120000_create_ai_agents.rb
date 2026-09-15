class CreateAiAgents < ActiveRecord::Migration[8.1]
  # ERPmine group permission, shown on Settings > Group Permission.
  PERMISSIONS = [
    { name: 'ADD AGENT', short_name: 'ADD_AGT', modules: 'AI', plugin: 'ag' }
  ].freeze

  def change
    # Agent list
    create_table :ai_agents do |t|
      t.string  :name,        null: false
      t.text    :description
      t.boolean :active,      null: false, default: true, index: true
      t.timestamps
    end
    add_index :ai_agents, :name, unique: true

    create_table :ai_agent_chats do |t|
      t.integer :ai_agent_id, null: false, index: true
      t.integer :user_id,     null: false, index: true
      t.string  :subject
      t.timestamps
    end
    add_index :ai_agent_chats, [:user_id, :created_at]

    create_table :ai_chat_messages do |t|
      t.integer :chat_id, null: false, index: true
      t.text    :request
      t.text    :response
      t.string  :provider
      t.string  :model
      t.timestamps
    end
    add_index :ai_chat_messages, [:chat_id, :created_at]

    reversible do |dir|
      dir.up   { seed_permissions }
      dir.down { WkPermission.where(short_name: PERMISSIONS.map { |p| p[:short_name] }).destroy_all }
    end
  end

  private

  def seed_permissions
    PERMISSIONS.each do |perm|
      next if WkPermission.exists?(short_name: perm[:short_name])

      # wk_permissions rows carry explicit ids; the sequence is not in step.
      perm = perm.merge(id: (WkPermission.unscoped.maximum(:id) || 0) + 1)
      WkPermission.create!(perm) rescue puts "Failed: #{perm[:short_name]}"
    end
  end
end
