require File.expand_path('../../test_helper', __FILE__)

# The approval gate has to read the same on the prompt, in the tool loop and on
# the reply. A run that is gated in the prompt never calls the tool the loop
# would have let through, so it previews an action nobody can approve.
class RedmineAgentApprovalTest < Redmine::ControllerTest
  tests RedmineAgentController

  fixtures :users, :email_addresses

  def setup
    @request.session[:user_id] = 1
    @agent = RedmineAgent::CustomAgents.create('name' => 'Approval Agent',
                                               'task' => 'post the summary',
                                               'created_by' => 1)
    Setting.plugin_redmine_agent = { 'agents' => ['Test|a-model|https://example.test/v1|key|1'],
                                     'human_in_the_loop' => '1' }
    Setting.rest_api_enabled = '1'
  end

  # Loads the page so the before_action resolves the agent; the gate reads the
  # header, not the verb.
  def visit_agent(token = nil)
    @request.headers[RedmineAgent::Runner::RUN_TOKEN_HEADER] = token if token
    get :index, params: { agent_key: @agent['key'] }
    assert_response :success
  end

  def gated?
    @controller.send(:approval_gate?)
  end

  def prompt
    @controller.send(:system_instructions, nil, tools: true)
  end

  def test_a_browser_request_is_gated
    visit_agent

    assert gated?
    assert_include 'HUMAN-IN-THE-LOOP APPROVAL (ENABLED)', prompt
  end

  def test_one_approval_covers_dependent_writes_for_the_previewed_action
    visit_agent

    assert_include 'complete the full previewed business action', prompt
    assert_include 'call them in the same approved turn without', prompt
    assert_include 'creating a resident requires', prompt
  end

  # The fix: a run was told to preview and wait, so it never called the tool.
  def test_a_run_request_is_not_gated
    visit_agent(RedmineAgent::Runner.token_for(@agent['key']))

    assert_not gated?
    assert_include 'HUMAN-IN-THE-LOOP APPROVAL (UNATTENDED RUN)', prompt
  end

  def test_a_forged_run_token_is_gated
    visit_agent('not-a-token')

    assert gated?
    assert_include 'HUMAN-IN-THE-LOOP APPROVAL (ENABLED)', prompt
  end

  # A token for someone else's agent proves nothing about this one.
  def test_a_run_token_for_another_agent_is_gated
    visit_agent(RedmineAgent::Runner.token_for('ag_someone_else'))

    assert gated?
  end

  # The token expires before a long run does, and the tool loop asks on every
  # iteration — the answer must not flip half way through.
  def test_the_gate_stays_off_when_the_token_expires_mid_run
    visit_agent(RedmineAgent::Runner.token_for(@agent['key']))
    assert_not gated?

    travel_to(Time.now + RedmineAgent::Runner::RUN_TOKEN_TTL + 60) do
      assert_not gated?
    end
  end

  def test_nothing_is_gated_when_approval_is_turned_off
    Setting.plugin_redmine_agent = Setting.plugin_redmine_agent.merge('human_in_the_loop' => '0')
    visit_agent

    assert_not gated?
    assert_include 'HUMAN-IN-THE-LOOP APPROVAL (DISABLED)', prompt
  end

  def finalize(text)
    @controller.send(:finalize_reply, { reply: text }, false, ['create_issue'])[:reply]
  end

  PREVIEW = "I will create the issue. [AWAITING_APPROVAL:create_issue]".freeze

  def test_a_browser_preview_keeps_its_approval_marker
    visit_agent

    assert_include RedmineAgentController::APPROVAL_MARKER, finalize(PREVIEW)
  end

  # Nobody can press Approve on a run, so a stray marker is noise in its log.
  def test_a_runs_reply_keeps_no_approval_marker
    visit_agent(RedmineAgent::Runner.token_for(@agent['key']))

    reply = finalize(PREVIEW)
    assert_not_include RedmineAgentController::APPROVAL_MARKER, reply
    assert_include 'I will create the issue.', reply
  end

  # ── Unattended runs never delete ──

  def validate(tool, args = { 'id' => 5 })
    @controller.send(:validate_tool_call, tool, args, nil)
  end

  # The prompt must not order the delete the tool loop now refuses.
  def test_a_run_prompt_does_not_order_deletes
    visit_agent(RedmineAgent::Runner.token_for(@agent['key']))

    assert_not_include 'and `delete_*` tools immediately', prompt
  end

  # A browser chat with approval off still gets the old wording.
  def test_the_disabled_block_is_unchanged_for_a_browser_chat
    Setting.plugin_redmine_agent = Setting.plugin_redmine_agent.merge('human_in_the_loop' => '0')
    visit_agent

    assert_include 'HUMAN-IN-THE-LOOP APPROVAL (DISABLED)', prompt
    assert_include 'and `delete_*` tools immediately', prompt
  end

  def test_delete_tool_recognises_destructive_names
    visit_agent

    assert @controller.send(:delete_tool?, 'delete_issue')
    assert @controller.send(:delete_tool?, 'slack_delete_message')
    assert @controller.send(:delete_tool?, 'remove_member')
    assert_not @controller.send(:delete_tool?, 'list_deleted_issues')
    assert_not @controller.send(:delete_tool?, 'create_issue')
  end

  # The hard stop: whatever the model decided, the loop refuses the call.
  def test_a_run_cannot_call_a_delete_tool
    visit_agent(RedmineAgent::Runner.token_for(@agent['key']))

    args, err = validate('delete_issue')
    assert_nil args
    assert_include 'NOT executed', err
  end

  # Not just Redmine's own tools — a delete on any server is refused.
  def test_a_run_cannot_delete_on_another_server
    visit_agent(RedmineAgent::Runner.token_for(@agent['key']))

    assert_nil validate('slack_delete_message').first
    assert_nil validate('remove_member').first
  end

  def test_a_run_can_still_call_a_write_tool
    visit_agent(RedmineAgent::Runner.token_for(@agent['key']))

    args, err = validate('create_issue', { 'subject' => 'x' })
    assert_nil err
    assert_equal({ 'subject' => 'x' }, args)
  end

  # Somebody is watching a browser chat, so its deletes are untouched.
  def test_a_browser_chat_can_still_call_a_delete_tool
    visit_agent

    args, err = validate('delete_issue')
    assert_nil err
    assert_equal({ 'id' => 5 }, args)
  end
end
