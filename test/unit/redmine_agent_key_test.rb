require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentKeyTest < ActiveSupport::TestCase
  def setup
    @existing = RedmineAgent::CustomAgents.create('name' => 'Existing key agent', 'task' => 'do it')
  end

  def test_database_rejects_duplicate_keys_without_model_validation
    assert_raises ActiveRecord::RecordNotUnique do
      AiAgent.transaction(requires_new: true) do
        AiAgent.new(name: 'Duplicate key agent', agent_key: @existing['key']).save!(validate: false)
      end
    end
    assert_equal 1, AiAgent.where(agent_key: @existing['key']).count
  end

  def test_legacy_rows_can_share_a_null_key
    first = AiAgent.create!(name: 'Legacy agent one')
    second = AiAgent.create!(name: 'Legacy agent two')
    assert_nil first.agent_key
    assert_nil second.agent_key
  end

  def test_validation_collision_generates_a_new_key
    SecureRandom.expects(:hex).with(4).twice.returns(@existing['key'].delete_prefix('ag_'), 'f00dcafe')
    agent = RedmineAgent::CustomAgents.create('name' => 'New key agent', 'task' => 'do it')
    assert_equal 'ag_f00dcafe', agent['key']
    assert AiAgent.exists?(id: agent['ai_agent_id'])
  end

  def test_database_collision_retries_outside_the_failed_savepoint
    # Emulate the uniqueness check passing before another process inserts
    # the key. The real database constraint must reject the first INSERT.
    AiAgent.any_instance.stubs(:valid?).returns(true)
    SecureRandom.expects(:hex).with(4).twice.returns(@existing['key'].delete_prefix('ag_'), 'f00dcafe')
    agent = RedmineAgent::CustomAgents.create('name' => 'Concurrent key agent', 'task' => 'do it')
    assert_equal 'ag_f00dcafe', agent['key']
    assert_equal 1, AiAgent.where(agent_key: @existing['key']).count
  end

  def test_unrelated_validation_errors_are_not_retried
    SecureRandom.expects(:hex).with(4).once.returns('f00dcafe')
    assert_raises ActiveRecord::RecordInvalid do
      RedmineAgent::CustomAgents.create('name' => @existing['name'], 'task' => 'do it')
    end
  end

  def test_repeated_collisions_stop_after_five_attempts
    SecureRandom.expects(:hex).with(4).times(5).returns(@existing['key'].delete_prefix('ag_'))
    assert_raises ActiveRecord::RecordInvalid do
      RedmineAgent::CustomAgents.create('name' => 'Repeated collision agent', 'task' => 'do it')
    end
  end
end
