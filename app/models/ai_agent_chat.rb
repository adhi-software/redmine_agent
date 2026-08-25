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

# A single chat session between a user and an AI agent. It groups the
# individual request/response messages (ai_chat_messages) and owns the
# user and agent they all belong to.
class AiAgentChat < ActiveRecord::Base
  belongs_to :ai_agent
  belongs_to :user
  has_many :ai_chat_messages, foreign_key: :chat_id, dependent: :destroy

  validates :ai_agent_id, presence: true
  validates :user_id, presence: true

  scope :for_user, ->(user) { where(user_id: user.id) }
  # The id tie-breaks rows created within the same timestamp tick: MySQL and
  # SQL Server store whole seconds / 3.33 ms steps, so created_at alone is not
  # a stable sort there.
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :oldest_first, -> { order(created_at: :asc, id: :asc) }
end
