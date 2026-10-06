require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentParamFilterTest < ActiveSupport::TestCase
  def setup
    @filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  def test_agent_secrets_are_filtered
    filtered = @filter.filter('api_key'   => 'sk-llm-secret',
                              'mcp_token' => 'xoxb-mcp-secret',
                              'settings'  => { 'agents'      => ['n|m|http://x|SECRETKEY|1'],
                                               'mcp_servers' => ['n|http://x|SECRETTOKEN|1'] })
    assert_equal '[FILTERED]', filtered['api_key']
    assert_equal '[FILTERED]', filtered['mcp_token']
    assert_equal '[FILTERED]', filtered['settings']['agents']
    assert_equal '[FILTERED]', filtered['settings']['mcp_servers']
  end

  def test_core_filters_still_apply
    filtered = @filter.filter('password' => 'pw', 'salt' => 's', 'twofa_totp_key' => 'k')
    assert_equal ['[FILTERED]'] * 3, filtered.values_at('password', 'salt', 'twofa_totp_key')
  end

  # Narrow by design: :token was rejected so authenticity_token stays readable.
  def test_non_secret_params_are_untouched
    filtered = @filter.filter('name' => 'Claude', 'url' => 'http://x', 'authenticity_token' => 'csrf')
    assert_equal 'Claude',     filtered['name']
    assert_equal 'http://x',   filtered['url']
    assert_equal 'csrf',       filtered['authenticity_token']
  end

  def test_each_filter_is_registered_exactly_once
    filters = Rails.application.config.filter_parameters
    [:api_key, :mcp_token, :agents, :mcp_servers].each do |p|
      assert_equal 1, filters.count(p), "#{p} should be registered once"
    end
  end
end
