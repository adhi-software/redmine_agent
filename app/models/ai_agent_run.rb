# One execution of a scheduled (or manually run) agent. Append-only log:
# when it ran, whether it succeeded, and a short preview of the reply. The
# full conversation lives in ai_chat_messages, not here.
class AiAgentRun < ActiveRecord::Base
  belongs_to :ai_agent, optional: false
  # The unique index on stamp is the claim; SQL Server allows only one NULL in
  # one, so a stampless row would break the dedupe there.
  validates :stamp, presence: true

  scope :for_agent, ->(id) { where(ai_agent_id: id) }
  scope :recent_first, -> { order(started_at: :desc, id: :desc) }
end
