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

module RedmineAgentHelper
  ALLOWED_HTML_TAGS = %w[
    p br strong em b i del s code pre a ul ol li
    table thead tbody tr th td h1 h2 h3 h4 h5 h6 blockquote hr
  ].freeze
  ALLOWED_HTML_ATTRS = { 'a' => %w[href title] }.freeze

  def render_markdown(text)
    text = text.to_s
    text = text.encode(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8

    html = Commonmarker.to_html(text, options: {
      render:    { unsafe: false, hardbreaks: false },
      extension: { table: true, autolink: true, strikethrough: true, tagfilter: true }
    })
    Sanitize.fragment(html,
      elements:       ALLOWED_HTML_TAGS,
      attributes:     ALLOWED_HTML_ATTRS,
      add_attributes: { 'a' => { 'rel' => 'noopener noreferrer', 'target' => '_blank' } }
    ).strip
  end

  def normalize_markdown(raw)
    raw.to_s.strip
       .gsub(/ > /, "\n")           # inline blockquote row separators → newlines
       .gsub(/^>\s*/, '')           # leading "> " at start of lines
       .gsub(/\|\s*\|/, "|\n|")     # table rows run together onto one line
  end

  # Convert the model's markdown reply into sanitized HTML for the web, plus
  # normalized markdown for clients that render it themselves (the mobile app).
  def parse_structured_reply(raw)
    cleaned = normalize_markdown(raw)

    { reply: raw.strip, type: 'html', html: render_markdown(cleaned), markdown: cleaned }
  end

  def user_chats(user)
    chats = AiAgentChat.for_user(user)
                       .includes(:ai_chat_messages)
                       .limit(500)

    result = chats.filter_map do |chat|
      rows = chat.ai_chat_messages.sort_by { |m| [m.created_at, m.id] }
      next if rows.empty?

      {
        chat_id:    chat.id,
        title:      chat.subject.presence || rows.first.request.to_s,
        created_at: rows.last.created_at.iso8601,
        exchanges:  rows.map { |d|
          cleaned = normalize_markdown(d.response)
          { request: d.request, reply: d.response.to_s,
            html: render_markdown(cleaned), markdown: cleaned }
        }
      }
    end

    result.sort_by { |c| [c[:created_at], c[:chat_id]] }.reverse
  end

  # Find the current user's chat by id, or start a new one. The
  # first message becomes the chat's subject.
  def find_or_create_chat(chat_id, message)
    cid = chat_id.to_s.presence
    chat = (cid && cid.match?(/\A\d+\z/)) && AiAgentChat.for_user(User.current).find_by(id: cid)
    chat || AiAgentChat.create!(
      ai_agent: default_agent,
      user:     User.current,
      subject:  message.to_s.truncate(255)
    )
  end

  def save_chat_message(message, result, provider, settings, chat)
    AiChatMessage.create!(
      chat:         chat,
      request:      message,
      response:     result[:reply].to_s,
      provider:     provider,
      model:        resolve_models(settings, default: '').first
    )
  rescue => e
    Rails.logger.warn "Failed to save agent history: #{e.message}"
    nil
  end

  # Named from the menu caption, forced to :en so the row is looked up under one
  # stable name whatever language the user browses in. Looked up
  # case-insensitively so the row is found whatever the database's collation.
  # The retry covers the unique-index race between the lookup and the insert
  # (two concurrent first requests).
  def default_agent
    name = I18n.t(:label_agent_query, locale: :en)
    AiAgent.named(name).first ||
      AiAgent.create!(name: name, description: 'Default Redmine chat agent')
  rescue ActiveRecord::RecordNotUnique
    AiAgent.named(name).first
  end

  def mcp_server_url
    "#{Setting.protocol}://#{Setting.host_name}".chomp('/') + '/mcp'
  end

  def agent_model_configured?
    Array(Setting.plugin_redmine_agent['agents']).reject(&:blank?).any?
  end

  def mcp_installed?
    Redmine::Plugin.installed?(:redmine_mcp)
  end

  def show_agent_menu?
    errors = []
    errors << I18n.t(:error_agent_no_model_config) unless agent_model_configured?
    errors << I18n.t(:error_agent_rest_api_disabled) if mcp_installed? && !Setting.rest_api_enabled?
    errors
  end
end
