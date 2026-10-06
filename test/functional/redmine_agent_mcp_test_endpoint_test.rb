require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentMcpTestEndpointTest < Redmine::ControllerTest
  tests RedmineAgentController

  fixtures :users, :email_addresses

  def setup
    @request.session[:user_id] = 1
    @captured = nil
    captured_ref = ->(server) { @captured = server }
    @controller.define_singleton_method(:mcp_handshake) do |server|
      captured_ref.call(server)
      ['sess-1', nil, '2024-11-05']
    end
    @controller.define_singleton_method(:mcp_tool_list) { |*| [] }
  end

  def test_token_is_read_from_the_mcp_token_param
    post :test_mcp_server, params: { name: 'slack', url: 'https://mcp.example.test',
                                     mcp_token: 'xoxb-secret' }

    assert_response :success
    assert JSON.parse(response.body)['success']
    assert_equal 'xoxb-secret',              @captured[:token]
    assert_equal 'https://mcp.example.test', @captured[:url]
    assert_equal 'slack',                    @captured[:name]
  end

  # The old param name must not still work, or the log filter would be bypassed.
  def test_legacy_token_param_is_ignored
    post :test_mcp_server, params: { name: 'slack', url: 'https://mcp.example.test',
                                     token: 'xoxb-secret' }

    assert_response :success
    assert_equal '', @captured[:token]
  end

  def test_blank_url_still_fails_gracefully
    post :test_mcp_server, params: { name: 'slack', url: '', mcp_token: 'x' }

    assert_response :success
    assert_not JSON.parse(response.body)['success']
  end
end
