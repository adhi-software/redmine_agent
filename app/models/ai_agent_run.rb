# One execution of a scheduled (or manually run) agent. Append-only log:
# when it ran, whether it succeeded, and a short preview of the reply. The
# full conversation lives in ai_chat_messages, not here.
class AiAgentRun < ActiveRecord::Base
  validates :agent_key, presence: true
  # The unique index on stamp is the claim; SQL Server allows only one NULL in
  # one, so a stampless row would break the dedupe there.
  validates :stamp, presence: true

  scope :for_agent, ->(key) { where(agent_key: key.to_s) }
  scope :recent_first, -> { order(started_at: :desc, id: :desc) }
end
