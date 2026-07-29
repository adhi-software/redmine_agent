# Represents a configured AI agent (an entry in the agent list).
class AiAgent < ActiveRecord::Base
  has_many :ai_agent_chats, dependent: :destroy
  has_many :ai_chat_messages, through: :ai_agent_chats

  # case_sensitive: false compares with LOWER() on every adapter, so the name is
  # unique the same way on MySQL (case-insensitive collation) and on
  # PostgreSQL / SQLite / SQL Server (case-sensitive by default).
  validates :name, presence: true, uniqueness: { case_sensitive: false }

  scope :active, -> { where(active: true) }
  # Match a name regardless of case on any database.
  scope :named, ->(name) { where('LOWER(name) = ?', name.to_s.downcase) }
end
