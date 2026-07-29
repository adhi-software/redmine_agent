# One request/response message within a chat, kept for history.
# The owning user and agent are reached through the chat.
class AiChatMessage < ActiveRecord::Base
  belongs_to :chat, class_name: 'AiAgentChat', foreign_key: :chat_id

  validates :chat_id, presence: true

  # id tie-breaks messages sharing a timestamp — see AiAgentChat.
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }
  scope :for_chat, ->(cid) { where(chat_id: cid) }
end
