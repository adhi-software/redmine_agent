# Redmine Agent
# Copyright (C) 2026-  Adhi software pvt ltd
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

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
