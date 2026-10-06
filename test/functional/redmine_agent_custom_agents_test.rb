require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentCustomAgentsTest < Redmine::ControllerTest
  tests RedmineAgentController

  fixtures :users, :email_addresses

  def setup
    @request.session[:user_id] = 1
    @agent = RedmineAgent::CustomAgents.create('name' => 'Rename Me', 'task' => 'do a thing',
                                               'created_by' => 1)
    @ai_agent = RedmineAgent::CustomAgents.ai_agent_record(@agent)
  end

  # ERPmine privileges are group-held, so granting one means joining a group.
  def grant_add_agent(user)
    group = Group.generate!
    group.users << user
    WkGroupPermission.create!(group: group, permission: WkPermission.find_by!(short_name: 'ADD_AGT'))
  end

  # Every run carries a stamp: the unique index on it is the scheduler's claim.
  def create_run(attrs = {})
    AiAgentRun.create!({ ai_agent_id: @agent['ai_agent_id'], stamp: "run-#{SecureRandom.hex(4)}",
                         status: 'ok', started_at: Time.now }.merge(attrs))
  end

  def test_rename_renames_the_linked_ai_agent_row
    patch :update_agent, params: { key: @agent['key'], name: 'Renamed Agent' }
    assert_response :success

    assert_equal 'Renamed Agent', RedmineAgent::CustomAgents.find(@agent['key'])['name']
    assert_equal 'Renamed Agent', @ai_agent.reload.name
  end

  # The JS matches this against the rendered sidebar href, which is a path.
  def test_menu_url_is_a_path_not_an_absolute_url
    patch :update_agent, params: { key: @agent['key'], name: 'Renamed Agent' }
    assert_response :success

    assert_equal "/redmine_agent?agent_key=#{@agent['key']}",
                 JSON.parse(response.body)['menu']['url']
  end

  def test_rename_keeps_the_same_ai_agent_row_and_its_chats
    chat = AiAgentChat.create!(ai_agent_id: @ai_agent.id, user_id: 1, subject: 'hello')

    patch :update_agent, params: { key: @agent['key'], name: 'Renamed Agent' }
    assert_response :success

    assert_equal @ai_agent.id, RedmineAgent::CustomAgents.find(@agent['key'])['ai_agent_id']
    assert_equal @ai_agent.id, chat.reload.ai_agent_id
  end

  def test_retask_updates_the_ai_agent_description
    patch :update_agent, params: { key: @agent['key'], task: 'a different thing' }
    assert_response :success

    assert_equal 'a different thing', @ai_agent.reload.description
  end

  def test_rename_to_another_agents_name_is_rejected
    other = RedmineAgent::CustomAgents.create('name' => 'Taken Name', 'task' => 'x')

    patch :update_agent, params: { key: @agent['key'], name: 'Taken Name' }
    assert_response :unprocessable_entity

    assert_equal 'Rename Me', RedmineAgent::CustomAgents.find(@agent['key'])['name']
    assert_equal 'Taken Name', RedmineAgent::CustomAgents.find(other['key'])['name']
  end

  # Renaming to the name it already has must not read as a duplicate.
  def test_rename_to_its_own_name_is_allowed
    patch :update_agent, params: { key: @agent['key'], name: 'Rename Me', task: 'still fine' }
    assert_response :success

    assert_equal 'still fine', RedmineAgent::CustomAgents.find(@agent['key'])['task']
  end

  def test_renamed_agent_is_listed_under_its_new_name
    patch :update_agent, params: { key: @agent['key'], name: 'Renamed Agent' }
    assert_response :success

    # The mobile app hits this endpoint with an API key, not a session.
    with_settings rest_api_enabled: '1' do
      @request.session[:user_id] = nil
      @request.headers['X-Redmine-API-Key'] = User.find(1).api_key
      get :agents, params: { format: 'json' }
    end
    assert_response :success
    names = JSON.parse(response.body)['agents'].map { |a| a['name'] }
    assert_includes names, 'Renamed Agent'
    assert_not_includes names, 'Rename Me'
  end

  def test_delete_removes_the_agents_run_log
    create_run
    other = RedmineAgent::CustomAgents.create('name' => 'Other', 'task' => 'x')
    create_run(ai_agent_id: other['ai_agent_id'])

    delete :destroy_agent, params: { key: @agent['key'] }
    assert_response :success

    assert_equal 0, AiAgentRun.for_agent(@agent['ai_agent_id']).count
    assert_equal 1, AiAgentRun.for_agent(other['ai_agent_id']).count, 'another agent\'s runs must survive'
  end

  def test_delete_removes_the_ai_agent_row_and_its_chats
    chat = AiAgentChat.create!(ai_agent_id: @ai_agent.id, user_id: 1, subject: 'hello')

    delete :destroy_agent, params: { key: @agent['key'] }
    assert_response :success

    assert_nil RedmineAgent::CustomAgents.find(@agent['key'])
    assert_nil AiAgent.find_by(id: @ai_agent.id)
    assert_nil AiAgentChat.find_by(id: chat.id)
  end

  # The shared default agent has no creator, so it is nobody's to manage.
  def test_query_agent_cannot_be_deleted
    query = RedmineAgent::CustomAgents.find(RedmineAgent::CustomAgents::QUERY_AGENT_KEY)
    delete :destroy_agent, params: { key: query['key'] }
    assert_response :forbidden

    assert RedmineAgent::CustomAgents.find(query['key']).present?
  end

  def test_create_rejects_a_blank_task
    grant_add_agent(User.find(1))
    assert_no_difference -> { RedmineAgent::CustomAgents.all.size } do
      post :create_agent, params: { name: 'No Task Agent', task: '  ' }
    end
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)['error'].present?
  end

  def test_update_rejects_a_blank_task
    patch :update_agent, params: { key: @agent['key'], task: '' }
    assert_response :unprocessable_entity

    assert_equal 'do a thing', RedmineAgent::CustomAgents.find(@agent['key'])['task']
  end

  def test_run_log_is_capped_per_agent
    cap = RedmineAgent::CustomAgents::MAX_RUNS_PER_AGENT
    (cap + 5).times do |i|
      create_run(stamp: "cap-#{i}", status: 'started', started_at: Time.now - (cap + 5 - i).minutes)
      RedmineAgent::CustomAgents.log_run(
        'key' => @agent['key'], 'stamp' => "cap-#{i}", 'status' => 'ok',
        'started_at' => Time.now - (cap + 5 - i).minutes
      )
    end

    assert_equal cap, AiAgentRun.for_agent(@agent['ai_agent_id']).count
    # The window keeps the newest, so the oldest entry is gone.
    assert_equal cap, AiAgentRun.for_agent(@agent['ai_agent_id']).recent_first.limit(cap).count
  end

  # There is no enabled/disabled concept, so the param must not hide an agent.
  def test_an_agent_stored_as_disabled_still_reaches_the_menu
    patch :update_agent, params: { key: @agent['key'], enabled: false }
    assert_response :success

    assert_includes RedmineAgent::CustomAgents.all.map { |a| a['key'] }, @agent['key']
  end

  def test_creator_can_manually_rerun_a_failed_scheduled_task
    failed = create_run(stamp: "#{@agent['key']}@2026-09-04 12:30", status: 'error', error: 'failed')
    RedmineAgent::Runner.expects(:run_async).with(has_entry('key' => @agent['key']), regexp_matches(/@manual /))

    post :run_agent, params: { key: @agent['key'] }
    assert_response :success
    run = AiAgentRun.find(JSON.parse(response.body)['run_id'])
    assert_not_equal failed.id, run.id
    assert_equal 'started', run.status
    assert_equal 'error', failed.reload.status
  end

  def test_run_now_does_not_need_a_schedule
    assert_nil @agent['cron'], 'this agent is deliberately schedule-less'
    # Stubbed: the real run posts a loopback HTTP request back into the app.
    RedmineAgent::Runner.stubs(:run_async).returns(nil)

    post :run_agent, params: { key: @agent['key'] }
    assert_response :success

    run = AiAgentRun.find(JSON.parse(response.body)['run_id'])
    assert_equal @agent['ai_agent_id'], run.ai_agent_id
    assert_equal 'started', run.status
  end

  # The run posts back into this app, so waiting for it here would hold one
  # request thread hostage to another.
  def test_run_now_does_not_wait_for_the_run
    RedmineAgent::Runner.stubs(:run_async).returns(nil)
    RedmineAgent::Runner.expects(:run).never

    post :run_agent, params: { key: @agent['key'] }
    assert_response :success
  end

  def test_run_now_does_not_execute_when_the_claim_is_unavailable
    RedmineAgent::CustomAgents.expects(:claim_run)
                             .with(@agent['key'], regexp_matches(/@manual /)).returns(nil)
    RedmineAgent::Runner.expects(:run_async).never

    assert_no_difference 'AiAgentRun.count' do
      post :run_agent, params: { key: @agent['key'] }
    end

    assert_response :conflict
    body = JSON.parse(response.body)
    assert_equal I18n.t(:error_agent_run_not_started), body['error']
    assert_not body.key?('run_id')
  end

  def test_run_now_does_not_execute_when_the_claim_raises_a_database_error
    RedmineAgent::CustomAgents.expects(:claim_run).raises(ActiveRecord::StatementInvalid, 'database unavailable')
    RedmineAgent::Runner.expects(:run_async).never

    assert_raises ActiveRecord::StatementInvalid do
      post :run_agent, params: { key: @agent['key'] }
    end
  end

  # The row is claimed up front so the browser can poll it, and a manual run
  # no longer writes a NULL stamp into a unique index.
  def test_run_now_rejects_an_overlapping_run_and_allows_one_after_completion
    RedmineAgent::Runner.stubs(:run_async).returns(nil)

    post :run_agent, params: { key: @agent['key'] }
    assert_response :success
    post :run_agent, params: { key: @agent['key'] }
    assert_response :conflict

    runs = AiAgentRun.for_agent(@agent['ai_agent_id'])
    assert_equal 1, runs.count
    runs.first.update!(status: 'ok', finished_at: Time.now)
    post :run_agent, params: { key: @agent['key'] }
    assert_response :success
    assert_equal 2, runs.count
    assert runs.all? { |run| run.stamp.present? }, 'a manual run must carry its own stamp'
  end

  def test_clearing_running_manual_history_does_not_allow_an_overlapping_run
    RedmineAgent::Runner.expects(:run_async).once
    post :run_agent, params: { key: @agent['key'] }
    run = AiAgentRun.find(JSON.parse(response.body)['run_id'])
    run.update!(started_at: 3.minutes.ago)

    RedmineAgent::CustomAgents.clear_runs(@agent['key'])
    assert_empty RedmineAgent::CustomAgents.runs(@agent['key'])
    post :run_agent, params: { key: @agent['key'] }
    assert_response :conflict

    RedmineAgent::CustomAgents.log_run('key' => @agent['key'], 'stamp' => run.stamp, 'status' => 'ok')
    assert_not_nil run.reload.finished_at
    assert_equal RedmineAgent::CustomAgents::CLEARED_STATUS, run.status
  end

  def test_run_now_rejects_a_task_less_agent
    RedmineAgent::CustomAgents.update(@agent['key'], 'task' => '')
    post :run_agent, params: { key: @agent['key'] }
    assert_response :unprocessable_entity
  end

  # The signed header skips the approval gate, so only a real run may claim it.
  # Deliberately owned by a non-admin, so no case can pass by way of an admin
  # exemption.
  def test_the_runner_header_is_honoured_for_the_agents_creator
    owned = RedmineAgent::CustomAgents.create('name' => 'Owned', 'task' => 'x',
                                              'created_by' => 2)
    @request.session[:user_id] = 2
    @request.headers[RedmineAgent::Runner::RUN_TOKEN_HEADER] =
      RedmineAgent::Runner.token_for(owned['key'])

    get :history, params: { agent_key: owned['key'] }
    assert_response :success
    assert @controller.send(:runner_request?)
  end

  # The gate used to trust this param, which any browser can send.
  def test_a_runner_param_alone_does_not_claim_a_run
    owned = RedmineAgent::CustomAgents.create('name' => 'Owned', 'task' => 'x',
                                              'created_by' => 2)
    @request.session[:user_id] = 2

    get :history, params: { agent_key: owned['key'], runner: '1' }
    assert_response :success
    assert_not @controller.send(:runner_request?)
  end

  # A token minted for one agent must not open another one's gate.
  def test_a_token_for_another_agent_is_refused
    owned = RedmineAgent::CustomAgents.create('name' => 'Owned', 'task' => 'x',
                                              'created_by' => 2)
    other = RedmineAgent::CustomAgents.create('name' => 'Other', 'task' => 'x',
                                              'created_by' => 2)
    @request.session[:user_id] = 2
    @request.headers[RedmineAgent::Runner::RUN_TOKEN_HEADER] =
      RedmineAgent::Runner.token_for(other['key'])

    get :history, params: { agent_key: owned['key'] }
    assert_response :success
    assert_not @controller.send(:runner_request?)
  end

  # The seeded Query Agent has no creator; that must fail closed.
  def test_the_runner_header_is_ignored_when_the_agent_has_no_creator
    query = RedmineAgent::CustomAgents.find(RedmineAgent::CustomAgents::QUERY_AGENT_KEY)
    assert_nil query['created_by'], 'the default agent is deliberately creator-less'
    @request.headers[RedmineAgent::Runner::RUN_TOKEN_HEADER] =
      RedmineAgent::Runner.token_for(query['key'])

    get :history, params: { agent_key: query['key'] }
    assert_response :success
    assert_not @controller.send(:runner_request?)
  end

  # The edit form is the only reader, so the payload carries what it fills in.
  def test_present_agent_carries_only_the_editable_fields
    get :custom_agents
    assert_response :success

    row = JSON.parse(response.body)['agents'].find { |a| a['key'] == @agent['key'] }
    assert_equal %w[cron key name task], row.keys.sort
  end

  def test_agent_runs_lists_the_whole_log_newest_first
    create_run(reply_excerpt: 'older', started_at: Time.now - 2.hours)
    create_run(status: 'error', error: 'boom', started_at: Time.now - 1.hour)
    other = RedmineAgent::CustomAgents.create('name' => 'Other', 'task' => 'x')
    create_run(ai_agent_id: other['ai_agent_id'])

    get :agent_runs, params: { key: @agent['key'] }
    assert_response :success

    runs = JSON.parse(response.body)['runs']
    assert_equal %w[error ok], runs.map { |r| r['status'] }, 'newest first'
    assert_equal 'boom', runs.first['error']
    assert_equal 'older', runs.last['reply_excerpt']
  end

  def test_agent_runs_is_capped_at_the_stored_window
    cap = RedmineAgent::CustomAgents::MAX_RUNS_PER_AGENT
    (cap + 5).times do |i|
      create_run(started_at: Time.now - i.minutes)
    end

    get :agent_runs, params: { key: @agent['key'] }
    assert_response :success
    assert_equal cap, JSON.parse(response.body)['runs'].size
  end

  def test_agent_runs_rejects_an_unknown_agent
    get :agent_runs, params: { key: 'ag_nope' }
    assert_response :unprocessable_entity
  end

  def test_agent_runs_is_owner_only
    @request.session[:user_id] = 2   # jsmith, who did not create @agent
    get :agent_runs, params: { key: @agent['key'] }
    assert_response :forbidden
  end

  def test_present_agent_reports_no_last_run_before_the_first_one
    get :custom_agents
    assert_response :success
    row = JSON.parse(response.body)['agents'].find { |a| a['key'] == @agent['key'] }
    assert_nil row['last_run']
  end

  def test_monthly_last_day_schedule_is_accepted_and_fires_every_month
    patch :update_agent, params: { key: @agent['key'], frequency: 'monthly', time: '09:00', day: 'L' }
    assert_response :success

    cron = RedmineAgent::CustomAgents.find(@agent['key'])['cron']
    assert_equal 'L', cron.split[2]

    parsed = Fugit::Cron.parse(cron)
    assert parsed, "#{cron.inspect} must be a valid cron"

    t = Time.utc(2026, 1, 15)
    months = 4.times.map { t = parsed.next_time(t).to_t; [t.month, t.day] }
    # Every month in a row — the point of L over a fixed 29/30/31.
    assert_equal [1, 2, 3, 4], months.map(&:first)
    assert_equal [31, 28, 31, 30], months.map(&:last)
  end

  def test_hourly_schedule_builds_an_hour_step_cron
    patch :update_agent, params: { key: @agent['key'], frequency: 'hourly', every: '4', minute: '30' }
    assert_response :success

    cron = RedmineAgent::CustomAgents.find(@agent['key'])['cron']
    assert_equal %w[30 */4 * * *], cron.split[0, 5]

    parsed = Fugit::Cron.parse(cron)
    t = Time.utc(2026, 1, 1)
    hours = 6.times.map { t = parsed.next_time(t).to_t; t.hour }
    # Even spacing, including across midnight — the point of restricting the
    # interval to 24's divisors.
    assert_equal 6, hours.uniq.size
    assert hours.each_cons(2).all? { |a, b| (b - a) % 24 == 4 }, hours.inspect
  end

  def test_hourly_every_1_uses_a_plain_star
    patch :update_agent, params: { key: @agent['key'], frequency: 'hourly', every: '1', minute: '0' }
    assert_response :success

    assert_equal %w[0 * * * *], RedmineAgent::CustomAgents.find(@agent['key'])['cron'].split[0, 5]
  end

  def test_an_interval_that_does_not_divide_24_is_rejected
    patch :update_agent, params: { key: @agent['key'], frequency: 'hourly', every: '5', minute: '0' }
    assert_response :unprocessable_entity

    assert_nil RedmineAgent::CustomAgents.find(@agent['key'])['cron']
  end

  # The form posts no frequency when only the name changed.
  def test_renaming_leaves_an_hourly_schedule_alone
    patch :update_agent, params: { key: @agent['key'], frequency: 'hourly', every: '2', minute: '15' }
    assert_response :success

    patch :update_agent, params: { key: @agent['key'], name: 'Renamed Hourly' }
    assert_response :success

    assert_equal %w[15 */2 * * *], RedmineAgent::CustomAgents.find(@agent['key'])['cron'].split[0, 5]
  end

  def test_monthly_day_31_skips_the_short_months
    patch :update_agent, params: { key: @agent['key'], frequency: 'monthly', time: '09:00', day: '31' }
    assert_response :success

    parsed = Fugit::Cron.parse(RedmineAgent::CustomAgents.find(@agent['key'])['cron'])
    t = Time.utc(2026, 1, 15)
    months = 3.times.map { t = parsed.next_time(t).to_t; t.month }
    # Documents why the form offers L: Feb and Apr never fire.
    assert_equal [1, 3, 5], months
  end

  # "Run once" is no schedule at all — the agent waits for its Run now button.
  def test_run_once_stores_no_schedule
    grant_add_agent(User.find(1))
    post :create_agent, params: { name: 'Run Once Agent', task: 'do a thing', frequency: 'once' }
    assert_response :success

    assert_nil JSON.parse(response.body)['agent']['cron']
  end

  def test_choosing_run_once_clears_an_existing_schedule
    patch :update_agent, params: { key: @agent['key'], frequency: 'daily', time: '09:30' }
    assert_response :success
    assert RedmineAgent::CustomAgents.find(@agent['key'])['cron'].present?

    patch :update_agent, params: { key: @agent['key'], frequency: 'once' }
    assert_response :success

    assert_nil RedmineAgent::CustomAgents.find(@agent['key'])['cron']
  end

  # ── Ownership: an agent belongs to whoever created it ──

  def test_a_non_admin_holding_add_agent_can_create_an_agent
    grant_add_agent(User.find(2))
    @request.session[:user_id] = 2
    post :create_agent, params: { name: 'Jsmiths Agent', task: 'do a thing' }
    assert_response :success

    key = JSON.parse(response.body)['agent']['key']
    assert_equal 2, RedmineAgent::CustomAgents.find(key)['created_by']
  end

  def test_a_non_admin_without_add_agent_cannot_create_an_agent
    @request.session[:user_id] = 2
    post :create_agent, params: { name: 'Jsmiths Agent', task: 'do a thing' }
    assert_response :forbidden

    assert_not RedmineAgent::CustomAgents.name_taken?('Jsmiths Agent')
  end

  # No admin bypass: the privilege is group-held for everyone.
  def test_an_admin_without_add_agent_cannot_create_an_agent
    assert User.find(1).admin?
    post :create_agent, params: { name: 'Admins Agent', task: 'do a thing' }
    assert_response :forbidden

    assert_not RedmineAgent::CustomAgents.name_taken?('Admins Agent')
  end

  def test_an_admin_holding_add_agent_can_create_an_agent
    grant_add_agent(User.find(1))
    post :create_agent, params: { name: 'Admins Agent', task: 'do a thing' }
    assert_response :success
  end

  def test_a_user_can_create_twenty_agents
    group = Group.generate!
    group.users << User.find(1)

    with_settings plugin_redmine_agent: { 'add_agent_group_id' => group.id.to_s } do
      20.times do |index|
        post :create_agent, params: { name: "Agent #{index + 1}", task: 'do a thing' }
        assert_response :success
      end
    end

    get :custom_agents
    assert_response :success
    names = JSON.parse(response.body)['agents'].map { |agent| agent['name'] }
    assert_equal (1..20).map { |number| "Agent #{number}" }, names.grep(/\AAgent \d+\z/)
  end

  def test_another_users_agent_is_not_listed
    other = RedmineAgent::CustomAgents.create('name' => 'Someone Elses', 'task' => 'x',
                                              'created_by' => 2)
    get :custom_agents
    assert_response :success

    keys = JSON.parse(response.body)['agents'].map { |a| a['key'] }
    assert_includes keys, @agent['key']
    assert_not_includes keys, other['key']
  end

  def test_the_mobile_agent_list_leaves_out_another_users_agent
    RedmineAgent::CustomAgents.create('name' => 'Someone Elses', 'task' => 'x', 'created_by' => 2)

    with_settings rest_api_enabled: '1' do
      @request.session[:user_id] = nil
      @request.headers['X-Redmine-API-Key'] = User.find(1).api_key
      get :agents, params: { format: 'json' }
    end
    assert_response :success

    names = JSON.parse(response.body)['agents'].map { |a| a['name'] }
    assert_includes names, 'Rename Me'
    assert_not_includes names, 'Someone Elses'
  end

  # A foreign key is indistinguishable from a missing one, so the chat 404s
  # instead of loading someone else's agent.
  def test_another_user_cannot_open_your_agents_chat
    @request.session[:user_id] = 2
    get :history, params: { agent_key: @agent['key'] }
    assert_response :missing
  end

  def test_the_default_agent_is_everyones
    @request.session[:user_id] = 2
    get :history
    assert_response :success
  end

  def test_another_user_cannot_change_or_delete_your_agent
    @request.session[:user_id] = 2

    patch :update_agent, params: { key: @agent['key'], name: 'Hijacked' }
    assert_response :forbidden

    delete :destroy_agent, params: { key: @agent['key'] }
    assert_response :forbidden

    assert_equal 'Rename Me', RedmineAgent::CustomAgents.find(@agent['key'])['name']
  end

  def test_another_user_cannot_run_your_agent
    @request.session[:user_id] = 2
    RedmineAgent::Runner.expects(:run).never

    post :run_agent, params: { key: @agent['key'] }
    assert_response :forbidden
  end

  # What the sidebar's per-request menu condition asks.
  def test_only_the_creator_sees_an_agent_in_the_menu
    assert RedmineAgent::CustomAgents.visible?(@agent['key'], @agent['created_by'], User.find(1))
    assert_not RedmineAgent::CustomAgents.visible?(@agent['key'], @agent['created_by'], User.find(2))

    query = RedmineAgent::CustomAgents.find(RedmineAgent::CustomAgents::QUERY_AGENT_KEY)
    assert RedmineAgent::CustomAgents.visible?(query['key'], query['created_by'], User.find(2))
  end

  # Registration is process-wide and the condition is what filters it, so it
  # has to answer correctly when the menu — not this module — calls it.
  def test_the_registered_menu_condition_hides_another_users_agent
    RedmineAgent::CustomAgents.sync_menu!
    item = Redmine::MenuManager.map(:agent_menu).menu_items.children
                               .find { |n| n.name == :"ai_agent_#{@agent['key']}" }
    assert item, 'the agent must be registered in the sidebar menu'

    User.current = User.find(1)
    assert item.condition.call(nil)
    User.current = User.find(2)
    assert_not item.condition.call(nil)
  ensure
    User.current = nil
  end

  # Renders the page itself: the sidebar and its "+" now belong to every user.
  def test_the_agent_page_renders_for_a_non_admin
    @request.session[:user_id] = 2
    get :index
    assert_response :success
  end


  def test_updating_only_the_schedule_leaves_the_ai_agent_row_alone
    patch :update_agent, params: { key: @agent['key'], frequency: 'daily', time: '09:30' }
    assert_response :success

    assert_equal 'Rename Me', @ai_agent.reload.name
    assert_equal 'do a thing', @ai_agent.description
    assert RedmineAgent::CustomAgents.find(@agent['key'])['cron'].present?
  end

  # ── The page's own history ──

  # A scheduled agent's page is its whole log: every run's chat, oldest first.
  def test_the_agent_page_carries_every_chat_oldest_first
    older = chat_with_message(@ai_agent, 'first run', 2.days.ago)
    newer = chat_with_message(@ai_agent, 'second run', 1.hour.ago)

    with_agent_configured { get :index, params: { agent_key: @agent['key'] } }
    assert_response :success

    assert_equal [older.id, newer.id], page_timeline['chats'].map { |c| c['chat_id'] }
  end

  def test_the_query_agent_page_carries_only_the_newest_chat
    query = RedmineAgent::CustomAgents.record_for(RedmineAgent::CustomAgents::QUERY_AGENT_KEY)
    chat_with_message(query, 'older', 2.days.ago)
    newest = chat_with_message(query, 'newest', 1.hour.ago)

    with_agent_configured { get :index }
    assert_response :success

    assert_equal [newest.id], page_timeline['chats'].map { |c| c['chat_id'] }
    assert_equal [], page_timeline['failed_runs']
  end

  # A failed run never produced a chat, so the page carries it separately.
  def test_the_agent_page_carries_the_failed_runs_only
    create_run(started_at: 2.hours.ago)
    create_run(status: 'error', error: 'boom', started_at: 1.hour.ago)

    with_agent_configured { get :index, params: { agent_key: @agent['key'] } }
    assert_response :success

    assert_equal ['boom'], page_timeline['failed_runs'].map { |r| r['error'] }
  end

  def test_invalid_schedule_inputs_do_not_change_the_saved_schedule
    patch :update_agent, params: { key: @agent['key'], frequency: 'daily', time: '09:30' }
    assert_response :success
    original = RedmineAgent::CustomAgents.find(@agent['key'])['cron']
    invalid = [
      { frequency: 'unknown', time: '09:00' },
      *%w[abc:30 09:xx 09:30:20 24:00 12:60].map { |time| { frequency: 'daily', time: time } },
      { frequency: 'hourly', every: '2oops', minute: '30' },
      { frequency: 'hourly', every: '2', minute: 'oops' },
      { frequency: 'hourly', every: '2' },
      { frequency: 'weekly', time: '09:00', weekday: '*' },
      { frequency: 'weekly', time: '09:00', weekday: '7' },
      { frequency: 'monthly', time: '09:00', day: '1,15' },
      { frequency: 'monthly', time: '09:00', day: '32' }
    ]
    invalid.each do |schedule|
      patch :update_agent, params: schedule.merge(key: @agent['key'])
      assert_response :unprocessable_entity
      assert_equal original, RedmineAgent::CustomAgents.find(@agent['key'])['cron']
    end
  end

  def test_create_rejects_unknown_frequency_and_malformed_time
    grant_add_agent(User.find(1))
    [{ frequency: 'unknown', time: '09:00' }, { frequency: 'daily', time: 'abc:30' }].each do |schedule|
      assert_no_difference 'AiAgent.count' do
        post :create_agent, params: schedule.merge(name: 'Invalid schedule', task: 'do a thing')
        assert_response :unprocessable_entity
      end
    end
  end

  private

  def chat_with_message(ai_agent, text, at)
    chat = AiAgentChat.create!(ai_agent_id: ai_agent.id, user_id: 1, subject: text)
    AiChatMessage.create!(chat: chat, request: text, response: 'done')
    chat.ai_chat_messages.update_all(created_at: at)
    chat
  end

  # Without a model configured the page renders the error notice instead.
  def with_agent_configured
    with_settings plugin_redmine_agent: { 'agents' => ['openai|gpt|https://api.test/v1|k|1'] },
                  rest_api_enabled: '1' do
      yield
    end
  end

  def page_timeline
    JSON.parse(css_select('#agent-initial-chats').first.text)
  end

end
