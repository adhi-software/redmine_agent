require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentSchedulerTest < ActiveSupport::TestCase
  fixtures :users, :email_addresses

  # 18:00 IST every day, and the tick times around it.
  CRON      = '0 18 * * * Asia/Kolkata'.freeze
  DUE       = Time.parse('2026-09-04 18:00:00 +0530')
  ON_TIME   = Time.parse('2026-09-04 18:00:30 +0530')
  # The following tick, still inside TICK_GRACE — the last one that can see
  # this occurrence at all.
  NEXT_TICK = Time.parse('2026-09-04 18:01:00 +0530')
  LAST_TICK = Time.parse('2026-09-04 18:02:00 +0530')   # exactly on the grace
  TOO_LATE  = Time.parse('2026-09-04 18:20:00 +0530')   # 20 min after DUE

  def setup
    @agent = RedmineAgent::CustomAgents.create(
      'name' => 'Sched Agent', 'task' => 'do it', 'cron' => CRON, 'created_by' => 1
    )
    schedule_set_at(Time.parse('2026-09-01 10:00:00 +0530'))
    # The run itself is a loopback HTTP request; only the claim is under test.
    RedmineAgent::Runner.stubs(:reachable?).returns(true)
    RedmineAgent::Runner.stubs(:run_async).returns(nil)
  end

  def tick_at(time)
    Time.stubs(:now).returns(time)
    RedmineAgent::Scheduler.send(:run_due_agents)
  end

  def schedule_set_at(time)
    AiAgent.find_by(agent_key: @agent['key']).update_column(:schedule_changed_at, time)
  end

  def runs
    AiAgentRun.for_agent(@agent['ai_agent_id'])
  end

  # Runner.run is stubbed out, so the claim is failed by hand.
  def fail_last_run
    runs.recent_first.first.update!(status: 'error', error: 'connection reset')
  end

  # ...and completed by hand: a claim left at 'started' is an interrupted run.
  def complete_last_run
    runs.recent_first.first.update!(status: 'ok')
  end

  def test_an_occurrence_runs_when_the_tick_lands_on_it
    tick_at(ON_TIME)

    assert_equal 1, runs.count
    assert_nil runs.first.finished_at
    assert_equal @agent['ai_agent_id'], runs.first.ai_agent_id
    # Stamped with the occurrence in UTC — 18:00 IST is 12:30 UTC.
    assert_equal "#{@agent['key']}@2026-09-04 12:30", runs.first.stamp
  end

  def test_the_same_occurrence_is_never_run_twice
    tick_at(ON_TIME)
    complete_last_run
    tick_at(NEXT_TICK)
    tick_at(LAST_TICK)

    assert_equal 1, runs.count
  end

  def test_a_new_occurrence_waits_while_a_manual_run_is_active
    Time.stubs(:now).returns(ON_TIME - 3.minutes)
    claim = RedmineAgent::CustomAgents.claim_run(@agent['key'], 'manual-busy')
    RedmineAgent::Runner.expects(:run_async).never
    tick_at(ON_TIME)
    assert_equal [claim.id], runs.pluck(:id)
  end

  def test_other_agents_can_still_claim_while_one_is_running
    first = RedmineAgent::CustomAgents.claim_run(@agent['key'], 'first')
    assert_nil RedmineAgent::CustomAgents.claim_run(@agent['key'], 'overlapping')
    other = RedmineAgent::CustomAgents.create('name' => 'Independent', 'task' => 'x', 'created_by' => 1)
    assert RedmineAgent::CustomAgents.claim_run(other['key'], 'other')
    first.update!(status: 'error', finished_at: Time.now)
    assert RedmineAgent::CustomAgents.claim_run(@agent['key'], 'after-error')
  end

  def test_a_claim_failure_does_not_skip_the_next_agent
    assert_next_agent_runs_after_failure(:claim)
    assert_equal 0, runs.count
  end

  def test_a_dispatch_failure_does_not_skip_the_next_agent_or_release_its_claim
    assert_next_agent_runs_after_failure(:dispatch)
    assert_equal 1, runs.count
    assert_equal 'started', runs.first.status
  end

  def assert_next_agent_runs_after_failure(stage)
    other = RedmineAgent::CustomAgents.create(
      'name' => 'Next scheduled agent', 'task' => 'do it', 'cron' => CRON, 'created_by' => 1
    )
    AiAgent.find(other['ai_agent_id']).update_column(:schedule_changed_at, DUE - 1.day)
    failed_stamp = "#{@agent['key']}@2026-09-04 12:30"
    other_stamp = "#{other['key']}@2026-09-04 12:30"
    if stage == :claim
      RedmineAgent::CustomAgents.expects(:claim_run).with(@agent['key'], failed_stamp)
                               .raises(StandardError, 'claim failed')
      RedmineAgent::CustomAgents.expects(:claim_run).with(other['key'], other_stamp).returns(true)
    else
      RedmineAgent::Runner.expects(:run_async).with(has_entry('key' => @agent['key']), failed_stamp)
                         .raises(StandardError, 'dispatch failed')
    end
    Rails.logger.expects(:warn).with(
      "RedmineAgent::Scheduler agent #{@agent['key']} failed: StandardError: #{stage} failed"
    )
    RedmineAgent::Runner.expects(:run_async).with(has_entry('key' => other['key']), other_stamp)

    tick_at(ON_TIME)

    if stage == :dispatch
      assert_equal 1, AiAgentRun.for_agent(other['ai_agent_id']).count
      assert_equal other_stamp, AiAgentRun.for_agent(other['ai_agent_id']).first.stamp
    end
  end

  # The point of the change: an occurrence the server was down for is dropped,
  # not backfilled when it comes back up.
  def test_an_occurrence_missed_while_down_is_dropped
    tick_at(TOO_LATE)

    assert_equal 0, runs.count
  end

  # Setting a 18:00 schedule at 18:30 must not fire that day's 18:00.
  def test_an_occurrence_older_than_the_schedule_is_dropped
    schedule_set_at(Time.parse('2026-09-04 18:30:00 +0530'))
    tick_at(Time.parse('2026-09-04 18:35:00 +0530'))

    assert_equal 0, runs.count
  end

  # An hour step still stamps the occurrence that just passed, not the tick:
  # the tick here is a minute past it.
  def test_an_hourly_interval_claims_the_occurrence_that_passed
    RedmineAgent::CustomAgents.update(@agent['key'], 'cron' => '0 */4 * * * Asia/Kolkata')
    # Move the schedule guard back so this test can exercise the occurrence.
    schedule_set_at(Time.parse('2026-09-01 10:00:00 +0530'))
    tick_at(Time.parse('2026-09-04 12:01:30 +0530'))

    assert_equal 1, runs.count
    # 12:00 IST is 06:30 UTC.
    assert_equal "#{@agent['key']}@2026-09-04 06:30", runs.first.stamp
  end

  # An edit is not a schedule change: renaming an agent must not cancel the
  # occurrence that is still inside its grace.
  def test_an_edit_that_leaves_the_schedule_alone_keeps_the_occurrence
    record = AiAgent.find(@agent['ai_agent_id'])
    updated_at = record.updated_at
    schedule_changed_at = record.schedule_changed_at
    travel 1.second
    RedmineAgent::CustomAgents.update(@agent['key'], 'name' => 'Renamed Agent')

    record.reload
    assert_operator record.updated_at, :>, updated_at
    assert_equal schedule_changed_at, record.schedule_changed_at

    tick_at(NEXT_TICK)

    assert_equal 1, runs.count
    assert_equal "#{@agent['key']}@2026-09-04 12:30", runs.first.stamp
  end

  # Changing the schedule must still re-arm the guard, or a newly set cron
  # back-fires the occurrence that just passed.
  def test_a_schedule_change_drops_the_occurrence_that_predates_it
    RedmineAgent::CustomAgents.update(@agent['key'], 'cron' => '0 18 * * 1-5 Asia/Kolkata')

    tick_at(NEXT_TICK)

    assert_equal 0, runs.count
  end

  def test_a_failed_occurrence_is_not_automatically_retried
    tick_at(ON_TIME)
    fail_last_run
    tick_at(NEXT_TICK)

    tick_at(LAST_TICK)
    assert_equal 1, runs.count
    assert_equal 'error', runs.first.status
    assert_equal "#{@agent['key']}@2026-09-04 12:30", runs.first.stamp
  end

  def test_a_failed_occurrence_does_not_block_the_next_regular_schedule
    tick_at(ON_TIME)
    fail_last_run
    tick_at(ON_TIME + 1.day)

    assert_equal 2, runs.count
    assert_equal "#{@agent['key']}@2026-09-05 12:30", runs.recent_first.first.stamp
  end

  def test_a_successful_occurrence_is_not_retried
    tick_at(ON_TIME)
    runs.first.update!(status: 'ok')
    tick_at(NEXT_TICK)

    assert_equal 1, runs.count
  end

  # The claim already exists, so the tick must not even reach the network.
  def test_a_claimed_occurrence_skips_the_reachability_probe
    tick_at(ON_TIME)
    complete_last_run
    RedmineAgent::Runner.unstub(:reachable?)
    RedmineAgent::Runner.expects(:reachable?).never

    tick_at(NEXT_TICK)
  end

# A process that died mid-run leaves its claim at 'started'; nothing else
# would ever move it, so the occurrence would be lost silently. It is shown
# but NOT retried: whether it wrote anything before dying is unknowable, and
# a retry would repeat it.
def test_a_claim_left_at_started_is_failed_but_not_retried
  tick_at(ON_TIME)
  runs.first.update!(started_at: DUE - 2 * 60 * 60)

  tick_at(NEXT_TICK)

  interrupted = AiAgentRun.find_by(stamp: "#{@agent['key']}@2026-09-04 12:30")
  assert_equal RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS, interrupted.status
  assert_equal 'run interrupted', interrupted.error
  assert_equal NEXT_TICK, interrupted.updated_at
  assert_nil interrupted.finished_at, 'the actual completion time is unknown'
  tick_at(LAST_TICK)
  assert_equal NEXT_TICK, interrupted.reload.updated_at, 'already failed runs must not be touched again'
  assert_equal 1, runs.count, 'an interrupted run must not be retried'
end

# The page lists anything error-shaped, so a partial failure is still visible.
def test_a_partial_failure_is_shown_but_never_retried
  tick_at(ON_TIME)
  runs.first.update!(status: RedmineAgent::CustomAgents::PARTIAL_ERROR_STATUS,
                     error: 'read timeout')

  tick_at(NEXT_TICK)

  assert_equal 1, runs.count
  assert runs.first.status.start_with?('error'), 'the page filters on an error prefix'
end

  # A run still in flight is not a dead claim.
  def test_a_fresh_claim_is_left_alone
    tick_at(ON_TIME)
    tick_at(NEXT_TICK)

    assert_equal 1, runs.count
    assert_equal 'started', runs.first.status
  end

  # The switch the mobile list already respects; the scheduler ignored it.
  def test_an_inactive_agent_never_runs
    AiAgent.find_by(agent_key: @agent['key']).update!(active: false)

    tick_at(ON_TIME)

    assert_equal 0, runs.count
  end

  # A run acts as its creator, so a locked account cannot run anything — and
  # must not log the same error on every occurrence either.
  def test_an_agent_whose_creator_is_locked_never_runs
    User.find(1).update_column(:status, User::STATUS_LOCKED)

    tick_at(ON_TIME)

    assert_equal 0, runs.count
  end

  # A Puma worker inherits the started flag but none of the threads.
  def test_the_scheduler_starts_once_per_process
    RedmineAgent::Scheduler.stubs(:non_server_process?).returns(false)
    fake = mock('rufus')
    fake.stubs(:cron)
    Rufus::Scheduler.expects(:new).twice.returns(fake)

    RedmineAgent::Scheduler.start!
    RedmineAgent::Scheduler.start!                        # same process: no-op
    forked = Process.pid + 1                              # read it before stubbing
    Process.stubs(:pid).returns(forked)
    RedmineAgent::Scheduler.start!                        # forked worker
  ensure
    RedmineAgent::Scheduler.instance_variable_set(:@started_pid, nil)
  end

  def test_scheduler_can_start_after_constructor_failure
    assert_startup_recovers(:constructor)
  end

  def test_scheduler_cleans_up_failed_cron_registration_and_can_start_again
    assert_startup_recovers(:registration)
  end

  def test_scheduler_clears_failed_start_state_even_when_cleanup_fails
    assert_startup_recovers(:cleanup)
  end

  def assert_startup_recovers(failure)
    scheduler_class = RedmineAgent::Scheduler
    old_pid = scheduler_class.instance_variable_get(:@started_pid)
    old_scheduler = scheduler_class.instance_variable_get(:@scheduler)
    scheduler_class.instance_variable_set(:@started_pid, nil)
    scheduler_class.stubs(:non_server_process?).returns(false)

    failed_scheduler = mock('failed scheduler')
    if failure == :constructor
      Rufus::Scheduler.stubs(:new).raises(StandardError, 'startup broken')
      failed_scheduler.expects(:shutdown).never
    else
      Rufus::Scheduler.stubs(:new).returns(failed_scheduler)
      failed_scheduler.expects(:cron).with('* * * * *').raises(StandardError, 'startup broken')
      if failure == :cleanup
        failed_scheduler.expects(:shutdown).raises(StandardError, 'cleanup broken')
        Rails.logger.expects(:warn).with('RedmineAgent::Scheduler cleanup failed: StandardError: cleanup broken')
      else
        failed_scheduler.expects(:shutdown).once
      end
    end
    Rails.logger.expects(:warn).with('RedmineAgent::Scheduler startup failed: StandardError: startup broken')
    scheduler_class.start!
    assert_nil scheduler_class.instance_variable_get(:@started_pid)
    assert_nil scheduler_class.instance_variable_get(:@scheduler)

    working_scheduler = mock('working scheduler')
    working_scheduler.expects(:cron).with('* * * * *').once
    Rufus::Scheduler.unstub(:new)
    Rufus::Scheduler.expects(:new).once.returns(working_scheduler)
    scheduler_class.start!
    scheduler_class.start!
    assert_equal Process.pid, scheduler_class.instance_variable_get(:@started_pid)
    assert_same working_scheduler, scheduler_class.instance_variable_get(:@scheduler)
  ensure
    scheduler_class.instance_variable_set(:@started_pid, old_pid)
    scheduler_class.instance_variable_set(:@scheduler, old_scheduler)
  end

  def test_an_agent_without_a_schedule_never_runs
    RedmineAgent::CustomAgents.update(@agent['key'], 'cron' => nil)
    tick_at(ON_TIME)

    assert_equal 0, runs.count
  end

  # The run log and the claim ledger are the same rows: deleting a recent claim
  # would hand the occurrence straight back to the next tick.
  def test_clearing_the_log_does_not_re_run_the_occurrence
    tick_at(ON_TIME)
    complete_last_run

    RedmineAgent::CustomAgents.clear_runs(@agent['key'])
    tick_at(NEXT_TICK)

    assert_equal 1, runs.count
    assert_equal RedmineAgent::CustomAgents::CLEARED_STATUS, runs.first.status
  end

  # ...and a cleared claim is not a failed one, so it is never retried either.
  def test_clearing_a_failed_run_neither_shows_it_nor_retries_it
    tick_at(ON_TIME)
    fail_last_run

    RedmineAgent::CustomAgents.clear_runs(@agent['key'])
    tick_at(NEXT_TICK)

    assert_equal 1, runs.count
    assert_equal RedmineAgent::CustomAgents::CLEARED_STATUS, runs.first.status
    assert_equal 0, runs.where(status: 'error').count
    assert_nil runs.first.error
  end

  # Past the grace the row is dead weight, so a clear really clears.
  def test_clearing_drops_a_run_past_the_grace
    AiAgentRun.create!(ai_agent_id: @agent['ai_agent_id'], stamp: "#{@agent['key']}@2026-09-04 02:30", status: 'ok',
                       started_at: DUE - 10 * 60 * 60)
    Time.stubs(:now).returns(ON_TIME)

    RedmineAgent::CustomAgents.clear_runs(@agent['key'])

    assert_equal 0, runs.count
  end

  # The 50-row cap must not evict a claim the scheduler could still act on.
  def test_pruning_keeps_a_claim_inside_the_grace
    cap = RedmineAgent::CustomAgents::MAX_RUNS_PER_AGENT
    (cap + 1).times do |i|
      AiAgentRun.create!(ai_agent_id: @agent['ai_agent_id'], stamp: "#{@agent['key']}@2026-09-04 12:#{format('%02d', i)}", status: 'ok',
                         started_at: DUE + i * 60)
    end
    Time.stubs(:now).returns(DUE + 60)

    RedmineAgent::CustomAgents.send(:prune_runs, @agent['key'])
    assert_equal cap + 1, runs.count, 'a claim inside the grace was pruned'

    # A manual run's stamp is unique per click, so the cap still evicts it.
    AiAgentRun.create!(ai_agent_id: @agent['ai_agent_id'], stamp: "#{@agent['key']}@manual beef",
                       status: 'ok', started_at: DUE - 60)
    RedmineAgent::CustomAgents.send(:prune_runs, @agent['key'])
    assert_equal cap + 1, runs.count, 'a manual run escaped the cap'

    # Once the grace has passed, the oldest is free to go.
    Time.stubs(:now).returns(DUE + RedmineAgent::Scheduler::TICK_GRACE + 60 * 60)
    RedmineAgent::CustomAgents.send(:prune_runs, @agent['key'])

    assert_equal cap, runs.count
  end

  # Pretends this process was started by `bin/rails s`.
  def with_server_command
    already = defined?(Rails::Command::ServerCommand)
    Rails::Command.const_set(:ServerCommand, Class.new) unless already
    yield
  ensure
    Rails::Command.send(:remove_const, :ServerCommand) unless already
  end

  def non_server?
    RedmineAgent::Scheduler.send(:non_server_process?)
  end

# Hides the constants the old name-by-name list knew about, leaving exactly
# the state a `bin/rails assets:precompile` boot has: a bin/rails process
# that none of those names match.
def as_unlisted_bin_rails_task
  hidden = {}
  [[Rails, :Console], [Rails::Command, :RunnerCommand],
   [Rails::Command, :TestCommand], [Rails::Command, :DbconsoleCommand]].each do |mod, name|
    next unless mod.const_defined?(name, false)

    hidden[[mod, name]] = mod.const_get(name, false)
    mod.send(:remove_const, name)
  end
  yield
ensure
  hidden.each { |(mod, name), value| mod.const_set(name, value) }
end

# The point of the change: a task nobody listed is still not a server.
def test_an_unlisted_bin_rails_task_is_not_a_server
  as_unlisted_bin_rails_task { assert non_server? }
end

  def test_the_server_command_is_a_server
    with_server_command { assert_not non_server? }
  end

  # The escape hatch stays, for running a scheduler somewhere unusual on purpose.
  def test_the_force_flag_overrides_the_guard
    ENV['AGENT_SCHEDULER'] = 'force'
    assert_not non_server?
  ensure
    ENV.delete('AGENT_SCHEDULER')
  end
end
