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

require 'net/http'
require 'openssl'
require 'uri'
require 'json'
require 'commonmarker'
require 'sanitize'

class RedmineAgentController < ApplicationController
  include RedmineAgentHelper

  before_action :require_login
  before_action :require_admin, only: [:test_model]

  accept_api_auth :index, :agents, :chat_request, :history, :clear

  menu_item :ai_agent_query

  def current_menu(project)
    :agent_menu
  end

  # Max sequential tool-call round-trips per user message.
  MAX_TOOL_ITERATIONS = 10

  def index
    @chat_url    = url_for(controller: '/redmine_agent', action: 'chat_request')
    @history_url = url_for(controller: '/redmine_agent', action: 'history')
    @clear_url   = url_for(controller: '/redmine_agent', action: 'clear')

    @greeting    = l(:label_redmine_agent_greeting, default: 'Hi! How can I help you today?')

    @initial_chat = user_chats(User.current).first
  end

  def chat_request
    message = params[:message].to_s.strip
    return render json: { error: 'Empty message' }, status: :unprocessable_entity if message.blank?

    # No MCP plugin means no tools at all: chat still works, the model just
    # answers from its own knowledge instead of from Redmine data.
    mcp_url = mcp_installed? ? mcp_server_url : nil

    chat    = find_or_create_chat(params[:chat_id], message)
    # Greetings don't need prior context
    history = greeting_only?(message) ? [] : chat_history(chat)
    provider = nil
    begin
      settings = active_agents(Setting.plugin_redmine_agent)
      provider = settings['type']

      # Nothing ran, so the answer never varies: skip the MCP handshake and
      # a full model turn (~10s measured) for a fixed sentence.
      if rejecting_pending_approval?(chat, message)
        return render_reply(l(:label_agent_action_cancelled), chat, message, provider, settings)
      end

      redmine_api_key = User.current.try(:api_key).presence || ''
      if greeting_only?(message) || mcp_url.blank?
        mcp_tools = session_id = mcp_instructions = nil
      else
        mcp_tools, session_id, mcp_instructions = fetch_mcp_tools(mcp_url, redmine_api_key)
        log_mcp_status(mcp_tools, mcp_url)
        raise l(:label_agent_mcp_tools_failed) if mcp_tools.blank?
      end

      mcp = { tools: mcp_tools, session_id: session_id, instructions: mcp_instructions }

      result = model_response(settings, mcp_url, message, history, mcp)
      chat_message = save_chat_message(message, result, provider, settings, chat)
      render json: result.merge(id: chat_message&.id, chat_id: chat.id)
    rescue => e
      Rails.logger.error "AI chat request failed (#{provider}): #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      error_message = e.message.to_s[/:message\s*=>\s*"([^"]+)"/, 1] || e.message
      render json: { error: error_message }, status: :bad_gateway
    end
  end

  # Test a LLM config from the settings popup
  def test_model
    server_url = params[:server_url].to_s.strip
    api_key    = params[:api_key].to_s.strip
    model      = params[:model].to_s.split(',').first.to_s.strip
    name       = params[:name].to_s.strip.downcase

    raise l(:label_redmine_agent_test_fail) if server_url.blank?

    # Dispatch on the configured type/host only — never on the model name, since
    # OpenRouter serves anthropic/claude-* models over the OpenAI-compatible API.
    is_claude = (name == 'claude' || server_url.include?('anthropic.com'))

    # Claude's URL is used as entered; the OpenAI-compatible one is normalised
    # as in the chat path, so the button tests the URL a real request hits.
    uri  = URI.parse(is_claude ? server_url : chat_completions_url(server_url))
    http = build_http(uri, read_timeout: 15)
    req  = build_json_post(uri)

    if is_claude
      req['x-api-key']         = api_key
      req['anthropic-version'] = ANTHROPIC_VERSION
      req.body = {
        model:      model.presence,
        messages:   [{ role: 'user', content: 'ping' }],
        max_tokens: 1
      }.compact.to_json
    else
      req['Authorization'] = "Bearer #{api_key}" if api_key.present?
      req.body = {
        model:      model.presence,
        messages:   [{ role: 'user', content: 'ping' }],
        max_tokens: 1,
        stream:     false
      }.compact.to_json
    end

    response = http.request(req)
    unless response.is_a?(Net::HTTPSuccess)
      raise "HTTP #{response.code} #{response.message}"
    end

    # No message on success — the Connected indicator is the whole result.
    render json: { success: true }
  rescue => e
    Rails.logger.warn "Model test failed: #{e.class}: #{e.message}"
    render json: { success: false, message: e.message.presence || l(:label_redmine_agent_test_fail) }
  end

  # List the configured agents (from the DB) for the mobile sidebar.
  def agents
    begin
      default_agent
    rescue => e
      Rails.logger.warn "Failed to seed the default agent: #{e.message}"
    end

    agents = AiAgent.active.order(:name).map do |a|
      { id: a.id, name: a.name, description: a.description }
    end
    render json: { agents: agents }
  end

  # List this user's past chats for the History panel.
  def history
    render json: { chats: user_chats(User.current), errors: show_agent_menu? }
  end

  # Permanently delete a whole chat, scoped to the current user.
  def clear
    chat_id = params[:chat_id].to_s
    if chat_id.present? && chat_id.match?(/\A\d+\z/)
      AiAgentChat.for_user(User.current)
                 .where(id: chat_id)
                 .destroy_all
    end
    render json: { success: true }
  end

  private

  # Render a canned reply and store it, in the same shape as a model answer.
  def render_reply(text, chat, message, provider, settings)
    result = parse_structured_reply(text).merge(completed_actions: [])
    chat_message = save_chat_message(message, result, provider, settings, chat)
    render json: result.merge(id: chat_message&.id, chat_id: chat.id)
  end

  # First configured row, split into flat keys. Rows are pipe-encoded
  # name|model|server_url|api_key|connect_model. The trailing flag only records
  # the last Test Model verdict for the settings screen, so it is discarded here
  # — chat never gates on it.
  def active_agents(raw)
    agents = Array(raw['agents']).reject(&:blank?)
    raise l(:error_agent_no_model_config) if agents.empty?

    _name, model, server_url, api_key, = agents.first.to_s.split('|', 5)
    {
      'type'       => server_url.to_s.downcase.include?('anthropic') ? 'claude' : 'openai',
      'model'      => model.to_s,
      'server_url' => server_url.to_s,
      'api_key'    => api_key.to_s
    }
  end

  # Supports a comma-separated list, e.g. "llama3.2:latest, qwen2.5:latest".
  def resolve_models(settings, default: nil)
    list = settings['model'].to_s.split(',').map(&:strip).reject(&:blank?)
    list.presence || [default]
  end

  # Try each model in order; return the first success, re-raise if all fail.
  def try_models(models)
    last_error = nil
    models.each do |model|
      begin
        return yield(model)
      rescue => e
        last_error = e
        logger.warn("Model '#{model}' failed: #{e.message}; trying next model.")
      end
    end
    raise last_error
  end

  def fetch_mcp_tools(mcp_url, api_key)
    return [nil, nil, nil] if mcp_url.blank?

    session_id = nil

    # Phase 1 — first contact. Any failure here means the server isn't reachable.
    begin
      uri  = URI.parse(mcp_url)
      http = build_http(uri, read_timeout: 15)
      logger.info("MCP: sending initialize to #{uri}")
      init_response = mcp_post(http, uri, api_key, session_id, {
        jsonrpc: '2.0',
        id:      1,
        method:  'initialize',
        params:  {
          protocolVersion: '2025-03-26',
          capabilities:    {},
          clientInfo:      { name: 'redmine-agent', version: '1.0' }
        }
      })
    rescue => e
      Rails.logger.warn "MCP unreachable: #{e.message}"
      raise l(:label_agent_mcp_unreachable, url: mcp_url)
    end

    session_id = init_response['Mcp-Session-Id'] || init_response['mcp-session-id']
    init_body = JSON.parse(init_response.body) rescue {}
    mcp_instructions = init_body.dig('result', 'instructions').presence
    logger.info("MCP: initialized OK, session_id=#{session_id.inspect}, instructions=#{mcp_instructions.present? ? 'yes' : 'none'}")

    # Phase 2 — server is reachable; a failure here means tools couldn't load.
    begin
      mcp_post(http, uri, api_key, session_id, { jsonrpc: '2.0', method: 'notifications/initialized' })

      logger.info('MCP: sending tools/list')
      list_response = mcp_post(http, uri, api_key, session_id, {
        jsonrpc: '2.0',
        id:      2,
        method:  'tools/list',
        params:  {}
      })

      body  = JSON.parse(list_response.body)
      logger.info("MCP tools/list response: #{body.inspect.truncate(500)}")
      tools = Array(body.dig('result', 'tools'))
      if tools.empty?
        logger.warn('MCP: tools/list succeeded but returned no tools')
        return [nil, session_id, mcp_instructions]
      end

      # Raw MCP shape; each provider converts it to its own tool format.
      [tools, session_id, mcp_instructions]
    rescue => e
      Rails.logger.warn "MCP tools fetch failed: #{e.message}"
      raise l(:label_agent_mcp_tools_failed)
    end
  end

  # Execute a single MCP tool call.
  def call_mcp_tool(mcp_url, api_key, session_id, tool_name, arguments)
    return { error: 'No MCP URL configured' } if mcp_url.blank?

    uri  = URI.parse(mcp_url)
    http = build_http(uri, read_timeout: 30)

    call_response = mcp_post(http, uri, api_key, session_id, {
      jsonrpc: '2.0',
      id:      3,
      method:  'tools/call',
      params:  { name: tool_name, arguments: arguments }
    })

    return { error: 'Failed to call tool' } unless call_response

    parsed = JSON.parse(call_response.body)
    parsed['error'] ? { error: parsed['error'] } : (parsed['result'] || { success: true })
  rescue => e
    Rails.logger.warn "MCP tools/call failed: #{e.message}"
    { error: e.message }
  end

  # Used to stop the tool loop on the first error.
  def tool_result_error?(result)
    return false unless result.is_a?(Hash)

    !!(result[:error] || result['error'] || result[:isError] || result['isError'])
  end

  # Tool names that only read data — never recorded as a completed action.
  READ_TOOL_PREFIXES = %w[get_ list_].freeze
  # Data-changing tools, gated behind user approval when HITL is on.
  WRITE_TOOL_PREFIXES = %w[create_ update_ delete_].freeze
  # Marker on a preview awaiting approval; the JS hangs Approve/Reject off it.
  # The model names the tool; #finalize_reply keeps it only if that tool exists.
  APPROVAL_MARKER = '[AWAITING_APPROVAL]'.freeze
  # Captures the tool name when present, and still matches a bare or malformed
  # marker so it can be stripped either way.
  APPROVAL_MARKER_RE = /\[\s*AWAITING_APPROVAL\s*(?:[:=]\s*([a-z0-9_]+))?[^\]]*\]/i
  # Verbs a preview may use for each write prefix, so "log this time entry"
  # still resolves to create_time_entry when the marker is left unnamed.
  APPROVAL_VERBS = {
    'create' => %w[create creating add adding log logging new],
    'update' => %w[update updating change changing edit editing modify modifying set],
    'delete' => %w[delete deleting remove removing]
  }.freeze
  # Sent back instead of running a gated write, so the model previews it.
  HITL_NOTE = 'NOT EXECUTED — user approval required. Describe this action and its ' \
    'field values so the user can check them, end your reply with ' \
    '[AWAITING_APPROVAL:<the name of this tool>], and call no tool. On approval, run ' \
    'it with exactly those values.'.freeze
  # Sent back when the user rejects, so the model just acknowledges the cancel.
  HITL_CANCEL_NOTE = 'The user rejected this action, so it was NOT executed. Briefly ' \
    'acknowledge the cancellation. Do not call any tool and do not ask for approval again.'.freeze

  def hitl_enabled?
    Setting.plugin_redmine_agent['human_in_the_loop'].to_s == '1'
  end

  def write_tool?(name)
    WRITE_TOOL_PREFIXES.any? { |p| name.to_s.start_with?(p) }
  end

  # Write tools from the live MCP list; nothing outside this set is approvable.
  def available_write_tools(mcp_tools)
    Array(mcp_tools).map { |t| t['name'].to_s.downcase }.select { |n| write_tool?(n) }
  end

  def decision(message)
    message.to_s.strip.downcase.gsub(/[[:punct:]]+\z/, '')
  end

  def approved?(message)
    decision(message) == decision(l(:label_agent_approval_approve))
  end

  def rejected?(message)
    decision(message) == decision(l(:label_agent_approval_reject))
  end

  # True when this message rejects a preview that is still pending — i.e. the
  # chat's most recent reply carries the marker.
  def rejecting_pending_approval?(chat, message)
    return false unless hitl_enabled? && rejected?(message) && chat&.persisted?

    last = chat.ai_chat_messages.max_by { |m| [m.created_at, m.id] }
    last.present? && last.response.to_s.match?(APPROVAL_MARKER_RE)
  end

  # The record a successful write created or changed, e.g. "issue #42", so a
  # later turn reuses it. nil for reads, failures and id-less results.
  def completed_write_action(tool_name, result)
    name = tool_name.to_s
    return nil if READ_TOOL_PREFIXES.any? { |p| name.start_with?(p) }
    return nil if tool_result_error?(result)
    return nil unless result.is_a?(Hash)

    body = result.dig('structuredContent', 'body') || result.dig(:structuredContent, :body)
    return nil unless body.is_a?(Hash)

    key, record = body.find { |_k, v| v.is_a?(Hash) && (v['id'] || v[:id]) }
    return nil unless record

    "#{key} ##{record['id'] || record[:id]}"
  end

  # Low-level MCP HTTP POST.
  def mcp_post(http, uri, api_key, session_id, body)
    req = Net::HTTP::Post.new(uri.request_uri)
    req['Authorization']  = "Bearer #{api_key}"
    req['Content-Type']   = 'application/json'
    req['Accept']         = 'application/json, text/event-stream'
    req['Mcp-Session-Id'] = session_id if session_id.present?
    req.body = body.to_json

    response = http.request(req)
    raise response.message unless response.is_a?(Net::HTTPSuccess)
    response
  end

  # OPENAI-COMPATIBLE — Ollama, OpenAI, Gemini, DeepSeek, Groq, OpenRouter, ...

  def claude?(provider)
    provider.to_s.downcase == 'claude'
  end

  def model_response(settings, mcp_url, message, history = [], mcp = {})
    provider = settings['type']
    models = resolve_models(settings)

    redmine_api_key = User.current.try(:api_key).presence || ''
    session_id = mcp[:session_id]

    provider_tools = claude?(provider) ? convert_tools_for_claude(mcp[:tools]) : convert_tools_for_provider(mcp[:tools])
    write_tools    = available_write_tools(mcp[:tools])

    system_prompt = system_instructions(mcp[:instructions], tools: mcp_url.present?)

    try_models(models) do |model|
      messages = if claude?(provider)
                   build_messages(message, include_system: false, history: history)
                 else
                   build_messages(message, system_prompt: system_prompt, history: history)
                 end

      response = nil
      intermediate_text = +''   # any prose the model writes alongside its tool calls
      executed_tools = {}       # tool signature => cached result, to avoid re-running the same call
      stopped_on_error = false  # true when we broke out on a failed tool call
      completed_actions = []    # records created/changed this turn, for history
      awaiting_approval = false # true when a write is paused for user approval
      unavailable_tool = nil    # set when the model called a tool we don't have

      MAX_TOOL_ITERATIONS.times do |iteration|
        final_pass = (iteration == MAX_TOOL_ITERATIONS - 1)
        current_tools = final_pass ? nil : provider_tools

        begin
          response = call_provider_api(provider, model, settings, messages, current_tools, system_prompt, iteration: iteration)
        rescue UnavailableToolError => e
          logger.warn(e.message)
          unavailable_tool = e.tool_name
          break
        end

        turn_text = extract_provider_text(provider, response).strip
        intermediate_text << "\n" << turn_text if turn_text.present?

        tool_calls = extract_provider_tool_calls(provider, response)
        break if tool_calls.blank?

        messages << format_assistant_message(provider, response)

        # HITL: pause write tools until the user approves (reads still run).
        # Only "Approve" runs the action; "Reject" cancels without re-previewing.
        if hitl_enabled? && !approved?(message) && tool_calls.any? { |tc| write_tool?(tc[:name]) }
          awaiting_approval = !rejected?(message)
          note = awaiting_approval ? HITL_NOTE : HITL_CANCEL_NOTE
          if claude?(provider)
            messages << { role: 'user', content: tool_calls.map { |tc| { type: 'tool_result', tool_use_id: tc[:id], content: note, is_error: true } } }
          else
            tool_calls.each { |tc| messages << { role: 'tool', tool_call_id: tc[:id], name: tc[:name], content: note } }
          end
          break
        end

        had_error = false
        ran_new_tool = false

        if claude?(provider)
          tool_results = tool_calls.map do |tc|
            safe_args, err = validate_tool_call(tc[:name], tc[:args])
            if err
              logger.warn("Blocked bad Claude tool call #{tc[:name]}: #{err}")
              had_error = true
              next { type: 'tool_result', tool_use_id: tc[:id], content: { error: err }.to_json, is_error: true }
            end

            result = call_mcp_tool(mcp_url, redmine_api_key, session_id, tc[:name], safe_args)
            logger.info("Claude tool result (#{tc[:name]}): #{result.inspect.truncate(400)}")
            is_err = tool_result_error?(result)
            had_error = true if is_err
            if (tag = completed_write_action(tc[:name], result))
              completed_actions << tag
            end

            { type: 'tool_result', tool_use_id: tc[:id], content: result.to_json, is_error: is_err }
          end

          messages << { role: 'user', content: tool_results }
        else
          tool_calls.each do |tc|
            safe_args, err = validate_tool_call(tc[:name], tc[:args])
            if err
              messages << { role: 'tool', tool_call_id: tc[:id], name: tc[:name], content: { error: err }.to_json }
              had_error = true
              next
            end

            signature = "#{tc[:name]}(#{safe_args.to_json})"
            if executed_tools.key?(signature)
              tool_result = executed_tools[signature]
              logger.info("Reusing cached tool result for #{signature}")
            else
              tool_result = executed_tools[signature] = call_mcp_tool(mcp_url, redmine_api_key, session_id, tc[:name], safe_args)
              ran_new_tool = true
              logger.info("Tool result (#{tc[:name]}): #{tool_result.inspect.truncate(400)}")
            end
            had_error = true if tool_result_error?(tool_result)
            if (tag = completed_write_action(tc[:name], tool_result))
              completed_actions << tag
            end

            messages << { role: 'tool', tool_call_id: tc[:id], name: tc[:name], content: tool_result.to_json }
          end
        end

        # Stop on the first tool error: don't keep retrying a failing call.
        if had_error
          stopped_on_error = true
          break
        end
        break if !claude?(provider) && !ran_new_tool
      end

      # Nothing ran and no other model has the tool either, so answer plainly
      # instead of letting the provider's validation error reach the user.
      if unavailable_tool
        next parse_structured_reply(l(:label_agent_tool_unavailable, action: unavailable_tool.tr('_', ' ')))
               .merge(completed_actions: [])
      end

      # Resolve the final reply
      primary = stopped_on_error ? '' : extract_provider_text(provider, response)
      reply = resolve_reply(primary, intermediate_text) do
        forced = call_provider_api(provider, model, settings, messages, nil, system_prompt)
        extract_provider_text(provider, forced)
      end
      # HITL: keep the approval marker only for a write tool that exists — see
      # #finalize_reply.
      reply = finalize_reply(reply, awaiting_approval, write_tools)
      reply.merge(completed_actions: awaiting_approval ? [] : completed_actions.uniq)
    end
  end

  def call_provider_api(provider, model, settings, messages, tools, system_prompt = nil, iteration: 0)
    if claude?(provider)
      api_key = settings['api_key'].to_s.strip
      raise 'Claude API key is not configured.' if api_key.blank?

      server_url = settings['server_url'].to_s.strip
      raise 'Claude API URL is not configured.' if server_url.blank?
      uri = URI.parse(server_url)

      system_blocks = [{
        type: 'text',
        text: system_prompt.presence || system_instructions,
        cache_control: { type: 'ephemeral' }
      }]

      params = { model: model, max_tokens: 2048, system: system_blocks, messages: messages }
      params[:tools] = tools if tools.present?

      claude_request(uri, api_key, params)
    else
      server_url = settings['server_url']
      raise 'Server URL is not configured.' if server_url.blank?

      uri = URI.parse(chat_completions_url(server_url))

      payload = { model: model, messages: messages, stream: true }
      payload[:tools] = tools if tools.present?

      logger.info("→ calling model (#{model}), iteration #{iteration}")
      assistant_message = stream_provider_message(uri, payload.to_json,
                                                  api_key: settings['api_key'].to_s.strip,
                                                  read_timeout: 500)
      logger.info("← stream complete")
      assistant_message
    end
  end

  def chat_completions_url(server_url)
    url = server_url.to_s.strip.chomp('/')

    return url if url.end_with?('/chat/completions')

    if url.end_with?('/openai')
      "#{url}/chat/completions"
    else
      "#{url}/v1/chat/completions"
    end
  end

  def extract_provider_text(provider, response)
    return '' if response.blank?
    if claude?(provider)
      claude_text(Array(response['content']))
    else
      response['content'].to_s
    end
  end

  def extract_provider_tool_calls(provider, response)
    return [] if response.blank?
    if claude?(provider)
      return [] unless response['stop_reason'] == 'tool_use'
      content = Array(response['content'])
      content.select { |b| b['type'] == 'tool_use' }.map do |block|
        {
          id:   block['id'],
          name: block['name'],
          args: normalise_arguments(block['input'].is_a?(Hash) ? block['input'] : JSON.parse(block['input'].to_s))
        }
      end
    else
      tool_calls = Array(response['tool_calls'])
      tool_calls.map do |tc|
        tc['id'] ||= "call_#{SecureRandom.hex(4)}"
        args_str = tc.dig('function', 'arguments') || '{}'
        args     = normalise_arguments(args_str.is_a?(String) ? JSON.parse(args_str) : args_str)
        {
          id:   tc['id'],
          name: tc.dig('function', 'name'),
          args: args
        }
      end
    end
  end

  def format_assistant_message(provider, response)
    if claude?(provider)
      { role: 'assistant', content: response['content'] }
    else
      response
    end
  end

  # Raw MCP tool → provider's function shape.
  def convert_tools_for_provider(mcp_tools)
    return [] if mcp_tools.blank?
    mcp_tools.map do |t|
      {
        type:     'function',
        function: {
          name:        t['name'],
          description: t['description'],
          parameters:  t['inputSchema'] || { type: 'object', properties: {} }
        }
      }
    end
  end

  TRANSIENT_HTTP_ERRORS = [
    OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::ECONNABORTED,
    Errno::EPIPE, EOFError, Net::OpenTimeout, IOError
  ].freeze

  # Raised when the model invents a tool we never sent. The system prompt tells
  # it to decline such actions, but smaller models call them anyway.
  class UnavailableToolError < StandardError
    attr_reader :tool_name

    def initialize(tool_name)
      @tool_name = tool_name.to_s
      super("Model called unavailable tool #{@tool_name}")
    end
  end

  # OpenAI-compatible servers validate tool calls against request.tools and kill
  # the stream on a miss. Captures the tool name from that message; anything
  # else is still reported as-is.
  UNAVAILABLE_TOOL_RE = /\btool ['"`]?([a-z0-9_]+)['"`]?\s+which was not in request\.tools/i

  def stream_provider_message(uri, payload_json, read_timeout:, api_key: nil, attempts: 3)
    last_error = nil
    attempts.times do |i|
      content    = +''
      tool_calls = {}   # index => { 'id', 'type', 'function' => { 'name', 'arguments' } }
      call_index = {}   # provider call id => index, for streams that omit `index`
      buffer     = +''
      begin
        http = build_http(uri, read_timeout: read_timeout)
        req  = build_json_post(uri)
        req['Accept'] = 'text/event-stream'
        req['Authorization'] = "Bearer #{api_key}" if api_key.present?
        req.body = payload_json

        http.request(req) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            # An error response carries a JSON body, not an SSE stream: report
            # what the provider said, falling back to the status line.
            body  = response.read_body.to_s
            error = (JSON.parse(body) rescue nil)
            error = error.first if error.is_a?(Array)  # Gemini wraps it in an array
            raise (error.dig('error', 'message') rescue nil).presence ||
                  "The model endpoint returned HTTP #{response.code} #{response.message}."
          end

          response.read_body do |chunk|
            buffer << chunk
            # SSE frames are newline-delimited "data: {...}" lines.
            while (nl = buffer.index("\n"))
              line = buffer.slice!(0..nl).chomp
              next unless line.start_with?('data:')
              data = line.sub(/\Adata:\s*/, '')
              next if data.empty? || data == '[DONE]'

              json = JSON.parse(data) rescue nil
              next unless json
              # A stream that opened with 200 can still fail mid-flight (Groq
              # reports bad function calls this way); dropping the frame would
              # look like an empty answer.
              if (err = json['error'])
                msg = (err.is_a?(Hash) ? err['message'] : err).to_s
                raise UnavailableToolError, msg[UNAVAILABLE_TOOL_RE, 1] if msg.match?(UNAVAILABLE_TOOL_RE)
                raise msg.presence || 'Model stream error'
              end
              delta = json.dig('choices', 0, 'delta') || {}

              content << delta['content'].to_s if delta['content']
              Array(delta['tool_calls']).each do |tc|
                # Gemini omits `index`, so parallel calls would all land in slot
                # 0 and have their arguments concatenated; key those on the id.
                idx  = tc['index'] || (call_index[tc['id']] ||= tool_calls.size)
                slot = tool_calls[idx] ||= { 'id' => nil, 'type' => 'function',
                                             'function' => { 'name' => +'', 'arguments' => +'' } }
                slot['id'] = tc['id'] if tc['id']
                # Gemini 3 sends a thought_signature here and rejects a later
                # turn replaying the call without it; a no-op for others.
                slot['extra_content'] = tc['extra_content'] if tc['extra_content']
                fn = tc['function'] || {}
                slot['function']['name'] = fn['name'] if fn['name'].present?
                slot['function']['arguments'] << fn['arguments'].to_s if fn['arguments']
              end
            end
          end
        end

        message = { 'role' => 'assistant', 'content' => content }
        message['tool_calls'] = tool_calls.keys.sort.map { |k| tool_calls[k] } if tool_calls.any?
        return message
      rescue *TRANSIENT_HTTP_ERRORS => e
        last_error = e
        logger.warn("OpenAI stream attempt #{i + 1}/#{attempts} failed (#{e.class}: #{e.message}); retrying on a fresh connection.")
        sleep(0.75 * (i + 1))
      end
    end
    raise last_error
  end

  # CLAUDE — Anthropic Messages API over net/http, no provider gem. The endpoint
  # comes from the configured server URL.

  ANTHROPIC_VERSION = '2023-06-01'.freeze

  # POST one request to the Anthropic Messages API and return the parsed body.
  # Raises with the API's error message on a non-success/error response.
  def claude_request(uri, api_key, payload)
    http = build_http(uri, read_timeout: 500)
    req  = build_json_post(uri)
    req['x-api-key']         = api_key
    req['anthropic-version'] = ANTHROPIC_VERSION
    req['anthropic-beta']    = 'prompt-caching-2024-07-31'
    req.body = payload.to_json

    response = http.request(req)
    parse_or_raise(response.body)
  end

  # Concatenate the text from Claude's response content blocks.
  def claude_text(content)
    Array(content).select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join("\n")
  end

  # Raw MCP tool → Claude's tool shape. The last tool carries a prompt-cache
  # breakpoint, so the list is cached instead of re-billed as input each turn.
  def convert_tools_for_claude(mcp_tools)
    return [] if mcp_tools.blank?
    tools = mcp_tools.map do |t|
      {
        name:         t['name'],
        description:  t['description'],
        input_schema: t['inputSchema'] || { type: 'object', properties: {} }
      }
    end
    tools.last[:cache_control] = { type: 'ephemeral' }
    tools
  end

  def greeting_only?(message)
    message.strip.match?(/\A(hi|hello|hey|greetings|good (morning|afternoon|evening)|thanks|thank you)[!.\s]*\z/i)
  end

  # Free-text instructions from plugin settings, appended to every system prompt.
  def custom_instructions
    Setting.plugin_redmine_agent['instructions'].to_s.strip
  end

  # Date and user facts the model has no other way to know, shared by the
  # tool-backed and the tool-free prompt.
  def agent_context
    # Injected so the model knows the real "today" (it has no clock) and can
    # resolve relative dates like "yesterday"/"tomorrow" the user mentions.
    today = Date.current

    # Calculate week start & end dates according to Redmine's Setting.start_of_week
    start_wday = Setting.start_of_week.presence&.to_i
    start_wday = l(:general_first_day_of_week, default: '1').to_i unless [1, 6, 7].include?(start_wday)
    start_of_week = today - ((today.cwday - start_wday) % 7)
    end_of_week   = start_of_week + 6

    # Injected for the same reason: without it the model spends a whole extra
    # tool round-trip on get_user(id: "current") before it can answer anything.
    user = User.current

    <<~CONTEXT
      CONTEXT: CURRENT DATE & CURRENT USER
      - Today is #{today.strftime('%A, %-d %B %Y')} (#{today.iso8601}). Yesterday was #{(today - 1).iso8601}, tomorrow is #{(today + 1).iso8601}.
      - "This week" starts on #{start_of_week.strftime('%A')} and spans from #{start_of_week.iso8601} to #{end_of_week.iso8601} (based on Redmine's week start setting).
      - Resolve "today", "current date", "now", "this week", "this month" and every other relative date from it. Never ask the date, and never guess it.
      - You are talking to #{user.name} — login #{user.login}, numeric ID #{user.id}, administrator: #{user.admin? ? 'yes' : 'no'}.
      - "current user", "logged user", "logged-in user", "me", "my" and "I" all mean that user. Never ask who they are, and never guess.
    CONTEXT
  end

  # How the reply is rendered, which doesn't depend on the tools being there.
  def reply_format
    <<~FORMAT
      FORMAT:
      Your replies are rendered as rich markdown (tables, bullet lists, bold, links), so use markdown formatting.
      - For action confirmations (create, update, delete): write a short confirmation sentence, then a bullet list with **Field:** Value for each key field. End with a brief follow-up offer (e.g. "Want to add more details?").
      - When the user asks for only ONE field of many records (e.g. "get users name", "list the project names", "just the logins"): output a simple markdown bullet list ("- value") of only that field's values — one per line. Do not use a table and do not add other columns.
      - For listing 3 or more records with multiple fields: use a markdown table with the most important columns. One row per line, with a header row and a |---| separator row.
      - For a single record's details: use a bullet list with **Field:** Value format.
      - For general questions: plain conversational text.
      Use **bold** for field labels. Flatten nested objects (status.name → status, project.name → project). Omit verbose or rarely-needed fields. Keep replies concise.
    FORMAT
  end

  # The prompt used when no tools were sent — the MCP plugin isn't installed, so
  def tool_free_instructions
    <<~PROMPT
      You are a helpful assistant inside Redmine, talking to a logged-in Redmine user.

      #{agent_context}
      WHAT YOU CAN DO:
      - You have no connection to this Redmine instance, so you cannot read, create, update or delete any record in it.
      - Answer general questions — arithmetic, definitions, explanations, writing help, how Redmine works in general — directly from your own knowledge.
      - If the user asks for data from this Redmine (their issues, projects, time entries, users, files, ...) or asks you to change something in it, say in one short sentence that you can't access this Redmine's data right now, then answer whatever part of the question you can from general knowledge.
      - Never claim you looked something up, never claim you carried out an action, and never ask the user to approve one.
      - If a request is ambiguous, ask exactly one short clarifying question.
      - The chat is continuous: when the user replies with just the detail you asked for, merge it with the earlier request instead of treating it as a new one.

      DATA RULES:
      - Never fabricate Redmine data — no issue numbers, project names, users, hours or dates from this instance.
      - Never mention APIs, HTTP, MCP, JSON, SQL, or internal implementation details.

      #{reply_format}
    PROMPT
  end

  def system_instructions(mcp_instructions = nil, tools: true)
    custom = custom_instructions
    suffix = custom.present? ? "\n#{<<~CUSTOM}" : ''
      ADDITIONAL INSTRUCTIONS:
      The following instructions come from the Redmine administrator and apply to every request.
      Follow them in addition to the rules above; where they conflict, they win — except for the
      DATA RULES, which always take precedence (never fabricate Redmine data).

      #{custom}
    CUSTOM

    # Nothing was sent that the model could call, so the tool rules and the
    # approval block don't apply — only the administrator's instructions still
    # ride along.
    return "#{tool_free_instructions}#{suffix}" unless tools

    prefix = mcp_instructions.present? ? "#{mcp_instructions}\n\n" : ''

    hitl_block =
      if hitl_enabled?
        <<~HITL

          HUMAN-IN-THE-LOOP APPROVAL (ENABLED)

          Before using any `create_*`, `update_*`, or `delete_*` tool:
          - Show a preview of the action and the field values.
          - End the response with `[AWAITING_APPROVAL:<tool_name>]`, naming the
            exact tool you will call once approved. The name is what puts the
            Approve / Reject buttons on your reply.
          - Call no tool in that response, and wait for the user's reply.
          - If the user approves, call that exact tool with exactly those values
            and report the result.
          - If the user declines or asks for something else, do NOT execute the
            tool. Briefly confirm it was cancelled and do not repeat the preview
            unless they ask again.
          - Never write the marker for an action that has no matching tool.

          Read-only tools (`get_*`, `list_*`) do not require approval.

        HITL
      else
        <<~HITL

          HUMAN-IN-THE-LOOP APPROVAL (DISABLED)

          Execute `create_*`, `update_*`, and `delete_*` tools immediately.
          Do not show a preview or ask for approval.

        HITL
      end

    "#{prefix}#{<<~PROMPT}#{hitl_block}#{suffix}"
      You are a Redmine assistant. Use the available MCP tools to answer questions about Redmine data.

      #{agent_context}
      TOOL USAGE RULES:
      - Only call a tool when the user requests Redmine data or an action. Don't call tools for greetings or general chat.
      - Answer general questions (arithmetic, definitions, explanations, writing help) directly from your own knowledge, without calling a tool. The tool requirement applies only to Redmine data, so don't refuse a question just because it isn't about Redmine.
      - You can only do what the available tools allow. If the request needs an action that has no matching tool (for example creating a project, when there is no create-project tool), say plainly in one short sentence that the action is not available here, and name the closest thing you can do if there is one. Never claim it was done, never preview it, and never ask the user to approve it.
      - Only pass parameters defined in the tool's input schema; never invent parameters or pass SQL/code. When a tool takes a "query" parameter, pass a JSON object (e.g. {"project_id": 3}), never a string.
      - Filters like "name" or "login" are optional. Include them only if the user gave a value; otherwise call the tool without them to return all records. Never ask the user for a filter value.
      - To list projects, call list_projects and show name, identifier, and Description.
      - To find a named user's projects, call list_users to get their numeric ID, then immediately call get_user with that id and query: {"include": "memberships"}. Do not stop between these steps.
      - To get issues for a named project, call list_projects to find its numeric ID, then list_issues with query: {project_id: <id>}.
      - If a request is ambiguous, ask exactly one short clarifying question.
      - Finish all required tool calls before writing anything
      - The chat is continuous. When you asked for a missing detail and the user replies with just that value, merge it with the pending request from earlier turns and complete that action — do not treat the reply as a brand-new, standalone request. Only disregard earlier turns when the current message clearly starts a new task or contradicts them.
      - An earlier assistant message may end with a line listing the records already created or changed in this chat. Those records already exist — never create them again. When you continue that request, reuse them instead of creating duplicates.
      - If you asked for several fields (e.g. Project Name and Subject) and the user replies with several lines, match each line to a field in the order you asked. The first line is the first field, the second line is the second field. Do not treat the whole reply as one field.

      DATA RULES:
      - Never fabricate Redmine data. Only use values returned by the tools.
      - If no records are returned, reply: "No matching records were found."
      - Never mention APIs, HTTP, MCP, JSON, SQL, pagination, or internal implementation details.
      - When listing a project's enabled modules, display the "boards" module as "Forums".
      - Use the conversation history only to understand context and follow-up replies (e.g. when the user answers a question you asked). Whenever the user asks to list, show, or get records, always call the relevant tool and use its fresh result — never copy a list or record out of an earlier reply, even if the very same request was just answered. The data may have changed (e.g. a project was archived or unarchived), so re-fetch it every time.

      COUNTING & TOTALS
      - Every list tool returns one page of records and a `total_count` field.
      - `total_count` is the authoritative count of all matching records. For any "how many" question (projects, issues, users, memberships, time entries, etc.), always use `total_count`. Never count only the records returned in the current page, as that will undercount.

      - Before calculating any total or aggregation (such as total hours, per-user totals, or per-project totals), fetch all matching records:
        1. Request the maximum page size (`limit=100`).
        2. Continue requesting additional pages by increasing the `offset` by 100.
        3. Stop only when the number of records retrieved equals `total_count`.

      - Time entries do not include a server-calculated hours total. Calculate it yourself by summing the `hours` value from every fetched record.

      - Verify all calculations before responding. The total hours reported must exactly equal the sum of the individual rows shown.

      - Any total displayed alongside a table must be calculated from that table's rows only. Never reuse totals from previous responses or different filters, users, projects, or date ranges. Always recompute using the current dataset.

      #{reply_format}
    PROMPT
  end

  def log_mcp_status(mcp_tools, mcp_url)
    logger.info("Fetched #{mcp_tools&.size.to_i} MCP tools.")
    logger.warn("No MCP tools available — check MCP URL: #{mcp_url.inspect}") if mcp_tools.blank?
  end

  # Builds the reply shown to the user.
  def resolve_reply(primary_text, intermediate_text)
    text = primary_text.to_s.strip
    if text.blank? && block_given?
      text = begin
        yield.to_s.strip
      rescue => e
        logger.warn("Forced final answer failed: #{e.message}")
        ''
      end
    end
    text = intermediate_text.to_s.strip if text.blank?
    parse_structured_reply(text)
  end

  # The Approve / Reject buttons hang off the marker, so it survives only when a
  # real write tool is waiting — the server paused the call, or the preview names
  # an available tool. Otherwise it renders as plain text, since approving a
  # tool we don't have could only ever produce an empty reply.
  def finalize_reply(reply, awaiting_approval, write_tools)
    text    = reply[:reply].to_s
    pending = hitl_enabled? &&
              (awaiting_approval || pending_write_tool(text, write_tools).present?)

    text = text.gsub(APPROVAL_MARKER_RE, '').strip
    text = (pending ? l(:label_agent_approval_prompt) : l(:label_agent_no_reply)) if text.blank?
    text = "#{text}\n\n#{APPROVAL_MARKER}" if pending
    parse_structured_reply(text)
  end

  # The tool a preview is waiting on, or nil when we can't run the action. The
  # model names it in the marker; on a bare marker, use the preview's wording.
  def pending_write_tool(text, write_tools)
    match = text.match(APPROVAL_MARKER_RE)
    return nil unless match

    named = match[1].to_s.downcase
    return (write_tools.include?(named) ? named : nil) if named.present?

    infer_write_tool(text, write_tools)
  end

  # Match the preview's words against each write tool: the action ("create") and
  # every word of its subject ("time", "entry") must both appear. With no
  # create_project tool, "I'll create this project" resolves to nothing.
  def infer_write_tool(text, write_tools)
    words = text.downcase.scan(/[a-z]+/).uniq
    write_tools.find do |tool|
      prefix, *subject = tool.split('_')
      next false if subject.empty?
      next false if (words & (APPROVAL_VERBS[prefix] || [prefix])).empty?

      subject.all? { |noun| words.include?(noun) || words.include?(noun.pluralize) }
    end
  end

  def build_messages(message, include_system: true, system_prompt: nil, history: [])
    msgs = []
    if system_prompt.present?
      msgs << { role: 'system', content: system_prompt }
    elsif include_system
      msgs << { role: 'system', content: system_instructions }
    end
    msgs.concat(history) if history.present?
    msgs << { role: 'user', content: message }
    msgs
  end

  # Max characters kept from each past response when replaying history.
  HISTORY_RESPONSE_LIMIT = 800

  def chat_history(chat, limit: 20)
    return [] unless chat&.persisted?

    chat.ai_chat_messages.sort_by { |m| [m.created_at, m.id] }.last(limit).flat_map do |msg|
      req  = msg.request.to_s
      resp = msg.response.to_s.truncate(HISTORY_RESPONSE_LIMIT)
      next [] if req.blank? || resp.blank?

      [{ role: 'user', content: req }, { role: 'assistant', content: resp }]
    end
  end

  def build_json_post(uri)
    req = Net::HTTP::Post.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req
  end

  def parse_or_raise(body_str)
    parsed = JSON.parse(body_str)
    if parsed['error']
      msg = parsed['error'].is_a?(Hash) ? parsed['error']['message'] : parsed['error'].to_s
      raise msg
    end
    parsed
  end

  # Usable CA bundle path, falling back to common OS paths when Ruby's OpenSSL
  # is mismatched. nil on Windows, where RubyInstaller's own store is used.
  def ssl_ca_file
    ENV['SSL_CERT_FILE'].presence ||
      %w[
        /etc/ssl/certs/ca-certificates.crt
        /etc/pki/tls/certs/ca-bundle.crt
        /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
        /etc/ssl/ca-bundle.pem
        /etc/pki/tls/cacert.pem
        /etc/ssl/cert.pem
        /opt/homebrew/etc/openssl@3/cert.pem
        /usr/local/etc/openssl@3/cert.pem
      ].find { |p| File.exist?(p) }
  end

  def build_http(uri, read_timeout: 300)
    http = Net::HTTP.new(uri.host, uri.port)
    if uri.scheme == 'https'
      http.use_ssl     = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ca = ssl_ca_file
      http.ca_file = ca if ca && File.exist?(ca)
    end
    http.open_timeout = 10
    http.read_timeout = read_timeout
    http
  end

  def normalise_arguments(args)
    return args unless args.is_a?(Hash)
    args.transform_values do |v|
      next v unless v.is_a?(String)
      next v unless v.match?(/\A[\[{]/)
      begin
        JSON.parse(v)
      rescue JSON::ParserError
        begin; JSON.parse(v.gsub("'", '"')); rescue JSON::ParserError; v; end
      end
    end
  end

  # True when an argument value looks like SQL, which weaker models sometimes pass.
  def sql_injected?(arguments)
    return false unless arguments.is_a?(Hash)
    arguments.any? do |_k, v|
      v.is_a?(String) && v.match?(/\b(select|from|join|where|insert|update|delete|drop|union)\b/i)
    end
  end

  # Strip known-bad keys that the model invents but the Redmine API does not accept.
  REDMINE_ALLOWED_PARAMS = %w[
    query
    id project_id issue_id user_id group_id membership_id relation_id
    status name login offset limit sort include
    spent_on from to activity_id hours comments
    subject description tracker_id priority_id assigned_to_id done_ratio
    issue body
  ].freeze

  def sanitise_arguments(tool_name, arguments)
    return arguments unless arguments.is_a?(Hash)
    cleaned = arguments.reject { |k, _| !REDMINE_ALLOWED_PARAMS.include?(k.to_s) }
    if cleaned.size != arguments.size
      removed = arguments.keys.map(&:to_s) - REDMINE_ALLOWED_PARAMS
      logger.warn("Removed unrecognised tool params for #{tool_name}: #{removed.inspect}")
    end
    cleaned
  end

  # Validate and clean arguments before sending to MCP.
  def validate_tool_call(tool_name, arguments)
    if sql_injected?(arguments)
      logger.warn("Blocked SQL in tool call #{tool_name}: #{arguments.inspect}")
      return [nil, "Invalid parameters for #{tool_name} — do not pass SQL. Use plain string values only."]
    end
    [sanitise_arguments(tool_name, arguments), nil]
  end
end
