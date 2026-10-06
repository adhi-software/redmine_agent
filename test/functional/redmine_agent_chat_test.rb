require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentChatTest < Redmine::ControllerTest
  tests RedmineAgentController

  fixtures :users, :email_addresses

  def setup
    @request.session[:user_id] = 1
    @agent = RedmineAgent::CustomAgents.create('name' => 'Chat Agent', 'task' => 'do a thing',
                                               'created_by' => 1)
    # Without a model row the page renders a config error instead of itself.
    Setting.plugin_redmine_agent = { 'agents' => ['Test|a-model|https://example.test/v1|key|1'] }
    Setting.rest_api_enabled = '1'
  end

  # No model is configured here, so the request fails after the chat is opened.
  def test_a_failed_request_leaves_no_empty_chat_behind
    assert_no_difference 'AiAgentChat.count' do
      post :chat_request, params: { message: 'do the thing', agent_key: @agent['key'] }
    end

    assert_response :bad_gateway
  end

  # What the page hands the JS to render.
  def initial_chat_titles
    JSON.parse(css_select('#agent-initial-chats').first.text)['chats'].map { |c| c['title'] }
  end

  def chat_at(ai_agent, subject, minutes)
    at   = Time.parse('2026-09-04 10:00:00 +0530') + minutes * 60
    chat = AiAgentChat.create!(ai_agent_id: ai_agent.id, user_id: 1, subject: subject,
                               created_at: at)
    AiChatMessage.create!(chat: chat, request: 'q', response: 'a', created_at: at)
    chat
  end

  # The page used to render every chat the user ever had here, then keep one.
  def test_the_query_agent_page_starts_with_only_the_newest_chat
    query = RedmineAgent::CustomAgents.ai_agent_record(RedmineAgent::CustomAgents::QUERY_AGENT_KEY)
    chat_at(query, 'older', 0)
    chat_at(query, 'newest', 10)

    get :index
    assert_response :success

    assert_equal ['newest'], initial_chat_titles
  end

  # A scheduled agent's page is a log: oldest at the top, newest at the bottom.
  def test_a_scheduled_agent_page_lists_its_chats_oldest_first
    ai_agent = RedmineAgent::CustomAgents.ai_agent_record(@agent)
    chat_at(ai_agent, 'first', 0)
    chat_at(ai_agent, 'second', 10)
    chat_at(ai_agent, 'third', 20)

    get :index, params: { agent_key: @agent['key'] }
    assert_response :success

    assert_equal %w[first second third], initial_chat_titles
  end

  # The Runner decides on a retry from this field, so a failure has to carry it.
  def test_a_failed_request_reports_that_nothing_ran
    post :chat_request, params: { message: 'do the thing', agent_key: @agent['key'] }

    assert_response :bad_gateway
    assert_equal false, JSON.parse(response.body)['executed']
  end

  # DNS resolution can fail briefly even when the provider is healthy. The
  # streaming request should use its existing bounded reconnect path instead
  # of exposing the first getaddrinfo failure to the chat user.
  def test_dns_and_connection_failures_are_transient
    errors = RedmineAgentController::TRANSIENT_HTTP_ERRORS

    assert_includes errors, SocketError
    assert_includes errors, Errno::ECONNREFUSED
    assert_includes errors, Errno::ETIMEDOUT
  end

  # ...and it is only ever set by a tool that changes data.
  def test_only_a_data_changing_tool_is_noted
    get :index, params: { agent_key: @agent['key'] }

    @controller.send(:note_write_tool, 'list_issues', nil)
    assert_not @controller.instance_variable_get(:@write_executed)

    @controller.send(:note_write_tool, 'create_issue', nil)
    assert @controller.instance_variable_get(:@write_executed)
  end

  def test_a_failed_read_reconnects_once_and_uses_the_fresh_session
    route = { name: 'redmine', url: 'https://mcp.example.test', token: 'secret',
              session_id: 'expired', protocol_version: 'old', remote_name: 'list_payments',
              write: false }
    routes = { 'list_payments' => route }

    @controller.expects(:call_mcp_route).twice
               .returns({ error: 'session expired' }, { 'payments' => [1] })
    @controller.expects(:mcp_handshake).with(route).returns(['fresh', nil, 'new'])

    result = @controller.send(:call_mcp_tool, routes, 'list_payments', {})

    assert_equal({ 'payments' => [1] }, result)
    assert_equal 'fresh', route[:session_id]
    assert_equal 'new', route[:protocol_version]
  end

  def test_a_failed_write_is_never_retried
    route = { name: 'Slack', url: 'https://mcp.example.test', token: 'secret',
              session_id: 'current', protocol_version: 'v1', remote_name: 'send_message',
              write: true }

    @controller.expects(:call_mcp_route).once.returns({ error: 'connection lost' })
    @controller.expects(:mcp_handshake).never

    assert_equal({ error: 'connection lost' },
                 @controller.send(:call_mcp_tool, { 'send_message' => route }, 'send_message', {}))
  end

  def test_the_second_scheduled_read_recovers_and_can_continue_to_notification
    first_route = { name: 'redmine', url: 'https://mcp.example.test', token: 'secret',
                    session_id: 'first', protocol_version: 'v1', remote_name: 'list_payments',
                    write: false }
    second_route = first_route.merge(session_id: 'expired')

    @controller.expects(:call_mcp_route).times(3).returns(
      { 'payments' => [1] },
      { error: 'session expired' },
      { 'payments' => [1] }
    )
    @controller.expects(:mcp_handshake).with(second_route).once
               .returns(['replacement', nil, 'v2'])

    first = @controller.send(:call_mcp_tool, { 'list_payments' => first_route },
                             'list_payments', {})
    second = @controller.send(:call_mcp_tool, { 'list_payments' => second_route },
                              'list_payments', {})

    assert_equal({ 'payments' => [1] }, first)
    assert_equal({ 'payments' => [1] }, second)
    assert_equal 'replacement', second_route[:session_id]
    assert_not @controller.send(:tool_result_error?, second),
               'the recovered read must not stop the tool loop before Slack'
  end
end
