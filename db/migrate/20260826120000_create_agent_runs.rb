class CreateAgentRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_runs do |t|
      t.string   :agent_key, null: false, index: true
      # Unique so two app processes can never both claim the same minute for
      # the same agent — the DB rejects the second INSERT. NULL for manual
      # "Run now" (Postgres treats NULLs as distinct, so those never collide).
      t.string   :stamp
      t.string   :status
      t.text     :reply_excerpt
      t.text     :error
      t.datetime :started_at
      t.timestamps
    end
    add_index :agent_runs, :stamp, unique: true
    add_index :agent_runs, [:agent_key, :started_at]
  end
end
