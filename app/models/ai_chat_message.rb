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
