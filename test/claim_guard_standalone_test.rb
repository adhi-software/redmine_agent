# Run without booting Rails or connecting to any database:
# bundle exec ruby plugins/redmine_agent/test/claim_guard_standalone_test.rb
require 'minitest/autorun'
require 'active_record'
require 'mocha/minitest'
require_relative '../lib/redmine_agent/custom_agents'
require_relative '../app/models/ai_agent_run'

module RedmineAgent
  class Scheduler
    STALE_CLAIM_AFTER = 900 unless const_defined?(:STALE_CLAIM_AFTER)
  end
end

class AgentClaimGuardStandaloneTest < Minitest::Test
  def setup
    @store = RedmineAgent::CustomAgents
    @agent = Object.new
    @agent.define_singleton_method(:id) { 7 }
    @agent.define_singleton_method(:with_lock) { |&block| block.call }
    @scope = mock('runs')
    @live = mock('live runs')
    @store.stubs(:record_for).with('agent').returns(@agent)
    AiAgentRun.stubs(:for_agent).with(7).returns(@scope)
    @scope.stubs(:where).with(status: ['started', 'cleared'], finished_at: nil).returns(@live)
    @live.stubs(:where).with('started_at >= ?', anything).returns(@live)
  end

  def test_busy_agent_does_not_dispatch_a_second_claim
    @live.expects(:exists?).returns(true)
    AiAgentRun.expects(:create!).never
    assert_nil @store.claim_run('agent', 'different-occurrence')
  end

  def test_finished_or_expired_agent_accepts_a_new_claim
    @live.expects(:exists?).returns(false)
    claim = Object.new
    AiAgentRun.expects(:create!).with(ai_agent: @agent, stamp: 'next', status: 'started', started_at: anything).returns(claim)
    assert_same claim, @store.claim_run('agent', 'next')
  end

  def test_duplicate_occurrence_is_still_rejected
    @live.expects(:exists?).returns(false)
    AiAgentRun.expects(:create!).raises(ActiveRecord::RecordNotUnique)
    assert_nil @store.claim_run('agent', 'duplicate')
  end

  def test_missing_agent_is_not_claimed
    @store.stubs(:record_for).with('gone').returns(nil)
    AiAgentRun.expects(:create!).never
    assert_nil @store.claim_run('gone', 'manual')
  end

  def test_competing_claims_check_busy_state_inside_the_same_lock
    # Substitute the row lock with a mutex: exercise real concurrent callers
    # without touching a database. Integration tests cover the AR persistence.
    mutex = Mutex.new
    busy = false
    created = []
    agent = Object.new
    agent.define_singleton_method(:id) { 7 }
    agent.define_singleton_method(:with_lock) { |&block| mutex.synchronize(&block) }
    live = Object.new
    live.define_singleton_method(:where) { |*| live }
    live.define_singleton_method(:exists?) { raise 'outside lock' unless mutex.owned?; busy }
    @store.stubs(:record_for).with('agent').returns(agent)
    @scope.stubs(:where).returns(live)
    creator = lambda do |**attrs|
      raise 'outside lock' unless mutex.owned?
      Thread.pass
      busy = true
      created << attrs[:stamp]
      attrs
    end
    original_create = AiAgentRun.method(:create!)
    AiAgentRun.define_singleton_method(:create!, creator)
    begin
      results = 8.times.map { |i| Thread.new { @store.claim_run('agent', "manual-#{i}") } }.map(&:value)
      assert_equal 1, results.compact.size
      assert_equal 1, created.size
    ensure
      AiAgentRun.define_singleton_method(:create!, original_create)
    end
  end
end
