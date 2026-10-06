require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentRunnerTest < ActiveSupport::TestCase
  fixtures :users, :email_addresses

  def setup
    @agent = RedmineAgent::CustomAgents.create(
      'name' => 'Runner Agent', 'task' => 'do it', 'created_by' => 1
    )
    # Core accepts a run's API key only while this is on.
    Setting.rest_api_enabled = '1'
  end

  # Net::HTTP is all that sits between the Runner and the chat endpoint.
  def stub_chat(klass, code, body)
    response = klass.new('1.1', code, '')
    response.stubs(:body).returns(body)
    Net::HTTP.any_instance.stubs(:request).returns(response)
  end

  # Every run carries one: the unique index on it is the scheduler's claim.
  def stamp(name)
    value = "#{@agent['key']}@#{name}"
    RedmineAgent::CustomAgents.claim_run(@agent['key'], value)
    value
  end

  def last_run
    AiAgentRun.for_agent(@agent['ai_agent_id']).recent_first.first
  end

  def test_a_chat_that_answers_is_logged_as_ok
    stub_chat(Net::HTTPOK, '200', { reply: 'all done' }.to_json)

    RedmineAgent::Runner.run(@agent, stamp('ok'))

    assert_equal 'ok', last_run.status
    assert_not_nil last_run.finished_at
    assert_operator last_run.finished_at, :>=, last_run.started_at
    assert_equal 'all done', last_run.reply_excerpt
  end

  # The endpoint renders {error: ...} with 502; that is a failed run, not an
  # empty reply.
  def test_a_failed_chat_is_logged_as_an_error
    stub_chat(Net::HTTPBadGateway, '502', { error: 'MCP tools failed', executed: false }.to_json)

    RedmineAgent::Runner.run(@agent, stamp('failed'))

    assert_equal 'error', last_run.status
    assert_not_nil last_run.finished_at
    assert_equal 'MCP tools failed', last_run.error
  end

  # A proxy or an error page answers with something that is not JSON.
  def test_a_failure_without_a_json_body_falls_back_to_the_status_line
    stub_chat(Net::HTTPInternalServerError, '500', '<html>oops</html>')

    RedmineAgent::Runner.run(@agent, stamp('html'))

    assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, last_run.status
    assert_includes last_run.error, '500'
  end

  # A spawned thread carries no execution context of its own, so the run has
  # to wrap itself.
  def test_run_async_executes_inside_the_rails_executor
    inside = false
    # A mocha with-block runs at call time, which is what makes it a probe.
    RedmineAgent::Runner.stubs(:run).with { inside = Rails.application.executor.active?; true }

    RedmineAgent::Runner.run_async(@agent, 'a stamp').join

    assert inside, 'the run must execute inside the Rails executor'
  end

  # A stampless row would take the one NULL a SQL Server unique index allows.
  def test_a_run_row_without_a_stamp_is_refused
    run = AiAgentRun.new(ai_agent_id: @agent['ai_agent_id'], status: 'ok', started_at: Time.now)

    assert_not run.valid?
    assert_includes run.errors.attribute_names, :stamp
  end

  def test_a_run_requires_an_existing_agent
    run = AiAgentRun.new(stamp: 'missing-agent', status: 'started')
    assert_not run.valid?
    assert_includes run.errors.attribute_names, :ai_agent
  end

  def test_a_token_is_valid_for_its_own_agent

    token = RedmineAgent::Runner.token_for(@agent['key'])

    assert RedmineAgent::Runner.valid_token?(token, @agent['key'])
    assert_not RedmineAgent::Runner.valid_token?(token, 'ag_someone_else')
  end

  def test_a_forged_or_missing_token_is_refused
    assert_not RedmineAgent::Runner.valid_token?(nil, @agent['key'])
    assert_not RedmineAgent::Runner.valid_token?('', @agent['key'])
    assert_not RedmineAgent::Runner.valid_token?('not-a-token', @agent['key'])
  end

  # A run is over in ~2 minutes; a token outliving that is a replay window.
  def test_a_token_expires
    token = RedmineAgent::Runner.token_for(@agent['key'])

    travel_to(Time.now + RedmineAgent::Runner::RUN_TOKEN_TTL + 60) do
      assert_not RedmineAgent::Runner.valid_token?(token, @agent['key'])
    end
  end

  # The claimed row is what the scheduler reads to decide on a retry.
  def test_a_failed_scheduled_run_fails_its_own_claim
    stamp = "#{@agent['key']}@2026-09-04 12:30"
    RedmineAgent::CustomAgents.claim_run(@agent['key'], stamp)
    stub_chat(Net::HTTPBadGateway, '502', { error: 'model timed out', executed: false }.to_json)

    RedmineAgent::Runner.run(@agent, stamp)

    assert_equal 1, AiAgentRun.for_agent(@agent['ai_agent_id']).count
    assert_equal 'error', AiAgentRun.find_by(stamp: stamp).status
  end

  # A turn that had already changed something must not be run again.
  def test_a_failure_after_a_write_is_not_retryable
    stub_chat(Net::HTTPBadGateway, '502', { error: 'model timed out', executed: true }.to_json)

    RedmineAgent::Runner.run(@agent, stamp('partial'))

    assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, last_run.status
  end

  # ...while a failure before any write keeps its retry — that is what the
  # retry is for (a model blip, a dropped MCP handshake).
  def test_a_failure_before_any_write_is_still_retryable
    stub_chat(Net::HTTPBadGateway, '502', { error: 'MCP tools failed', executed: false }.to_json)

    RedmineAgent::Runner.run(@agent, stamp('clean'))

    assert_equal 'error', last_run.status
  end

  # The chat keeps answering after we stop listening, so the work may be done.
  def test_a_read_timeout_is_not_retryable
    Net::HTTP.any_instance.stubs(:request).raises(Net::ReadTimeout)

    RedmineAgent::Runner.run(@agent, stamp('timeout'))

    assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, last_run.status
  end

  # An open timeout never delivered the request, so nothing ran.
  def test_an_open_timeout_is_retryable
    Net::HTTP.any_instance.stubs(:request).raises(Net::OpenTimeout)

    RedmineAgent::Runner.run(@agent, stamp('unreachable'))

    assert_equal 'error', last_run.status
  end

  # A body with no word on it is the old endpoint, or a proxy's error page.
  def test_a_failure_without_an_executed_flag_is_not_retryable
    stub_chat(Net::HTTPInternalServerError, '500', '<html>oops</html>')

    RedmineAgent::Runner.run(@agent, stamp('no-flag'))

    assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, last_run.status
  end

  def test_transport_failures_after_sending_are_not_retryable
    [EOFError, Errno::ECONNRESET, Errno::EPIPE].each do |error|
      Net::HTTP.any_instance.stubs(:request).raises(error)
      RedmineAgent::Runner.run(@agent, stamp(error.name))
      assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, last_run.status
      assert_not_nil last_run.finished_at
    end
  end

  def test_connection_refused_is_retryable
    Net::HTTP.any_instance.stubs(:request).raises(Errno::ECONNREFUSED)
    RedmineAgent::Runner.run(@agent, stamp('refused'))
    assert_equal 'error', last_run.status
  end

  def test_invalid_success_payloads_are_failed_without_retry
    ['<html>login</html>', '', 'null', '[]', '{}', '{"reply":null}',
     '{"reply":42}', '{"reply":"done","error":"failed"}'].each_with_index do |body, i|
      stub_chat(Net::HTTPOK, '200', body)
      RedmineAgent::Runner.run(@agent, stamp("invalid-#{i}"))
      assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, last_run.status
      assert_includes last_run.error, 'Invalid chat response'
      assert_not_nil last_run.finished_at
    end
  end

  def test_only_a_boolean_false_execution_flag_allows_retry
    [nil, true, 'false', 0].each_with_index do |executed, i|
      stub_chat(Net::HTTPBadGateway, '502', { error: 'failed', executed: executed }.to_json)
      RedmineAgent::Runner.run(@agent, stamp("unknown-#{i}"))
      assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, last_run.status
    end
  end

  # Core accepts the run's API key only while the REST web service is on, so
  # the run says that instead of reporting a bare 401 from the chat endpoint.
  def test_a_run_says_so_when_the_rest_api_is_off
    # with_settings restores it, so the off case cannot leak into another test.
    with_settings(rest_api_enabled: '0') do
      Net::HTTP.any_instance.expects(:request).never

      RedmineAgent::Runner.run(@agent, stamp('no-rest'))
    end

    assert_equal 'error', last_run.status
    assert_equal I18n.t(:error_agent_rest_api_disabled), last_run.error
  end
  def test_cleared_manual_and_old_scheduled_runs_are_not_recreated_on_completion
    ['manual clearing', '2026-09-01 12:30'].each do |suffix|
      value = stamp(suffix)
      AiAgentRun.find_by!(stamp: value).update!(started_at: 1.hour.ago)
      Net::HTTP.any_instance.stubs(:request).with do |_request|
        RedmineAgent::CustomAgents.clear_runs(@agent['key'])
        true
      end.returns(Net::HTTPOK.new('1.1', '200', 'OK').tap { |r| r.stubs(:body).returns('{"reply":"done"}') })
      RedmineAgent::Runner.run(@agent, value)
      assert_not AiAgentRun.exists?(stamp: value)
      assert_empty RedmineAgent::CustomAgents.runs(@agent['key'])
    end
  end

  def test_cleared_live_claim_is_not_overwritten_by_success_or_failure
    ['ok', 'error'].each_with_index do |status, i|
      value = stamp((Time.now.utc + i * 60).strftime('%Y-%m-%d %H:%M'))
      RedmineAgent::CustomAgents.clear_runs(@agent['key'])
      RedmineAgent::CustomAgents.log_run('key' => @agent['key'], 'stamp' => value,
        'status' => status, 'reply_excerpt' => 'done', 'error' => 'failed')
      run = AiAgentRun.find_by!(stamp: value)
      assert_equal RedmineAgent::CustomAgents::CLEARED_STATUS, run.status
      assert_nil run.reply_excerpt
      assert_nil run.error
      assert_empty RedmineAgent::CustomAgents.runs(@agent['key'])
    end
  end

end
