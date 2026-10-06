require File.expand_path('../../test_helper', __FILE__)

class RedmineAgentHelperTest < ActiveSupport::TestCase
  include RedmineAgentHelper

  fixtures :users, :email_addresses

  BASE = Time.parse('2026-09-04 10:00:00 +0530')

  def setup
    @user  = User.find(1)
    @agent = RedmineAgent::CustomAgents.create('name' => 'History Agent', 'task' => 'do it',
                                               'created_by' => @user.id)
    @ai_agent = RedmineAgent::CustomAgents.ai_agent_record(@agent)
  end

  def chat_at(subject, minutes, with_message: true)
    at   = BASE + minutes * 60
    chat = AiAgentChat.create!(ai_agent_id: @ai_agent.id, user_id: @user.id,
                               subject: subject, created_at: at)
    if with_message
      AiChatMessage.create!(chat: chat, request: "q #{subject}", response: "a #{subject}",
                            created_at: at)
    end
    chat
  end

  def titles(chats)
    chats.map { |c| c[:title] }
  end

  def test_chats_come_back_newest_first
    chat_at('oldest', 0)
    chat_at('middle', 10)
    chat_at('newest', 20)

    assert_equal %w[newest middle oldest], titles(user_chats(@user, @ai_agent))
  end

  # Without an ORDER BY the database picks the rows, so the newest chats can
  # fall outside the window entirely.
  def test_the_limit_takes_the_newest_chats_not_an_arbitrary_page
    chat_at('oldest', 0)
    chat_at('middle', 10)
    chat_at('newest', 20)

    assert_equal %w[newest middle], titles(user_chats(@user, @ai_agent, limit: 2))
  end

  # A run that failed before it answered leaves a chat with no messages.
  def test_an_empty_chat_never_uses_up_the_window
    chat_at('answered', 0)
    chat_at('empty', 20, with_message: false)

    assert_equal %w[answered], titles(user_chats(@user, @ai_agent, limit: 1))
  end

  def test_chats_are_scoped_to_their_agent
    other = RedmineAgent::CustomAgents.create('name' => 'Other Agent', 'created_by' => @user.id)
    chat_at('mine', 0)
    AiChatMessage.create!(
      chat: AiAgentChat.create!(ai_agent_id: RedmineAgent::CustomAgents.ai_agent_record(other).id,
                                user_id: @user.id, subject: 'theirs'),
      request: 'q', response: 'a'
    )

    assert_equal %w[mine], titles(user_chats(@user, @ai_agent))
  end
end
