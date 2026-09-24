class CreateAiAgents < ActiveRecord::Migration[8.1]
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
  end
end
