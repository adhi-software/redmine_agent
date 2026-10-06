require File.expand_path('../../test_helper', __FILE__)

# The "+" button is rendered by the main-menu patch, not by a controller action.
class RedmineAgentAddAgentTest < Redmine::ControllerTest
  tests RedmineAgentController

  fixtures :users, :email_addresses

  def grant_add_agent(user)
    group = Group.generate!
    group.users << user
    WkGroupPermission.create!(group: group, permission: WkPermission.find_by!(short_name: 'ADD_AGT'))
  end

  def test_the_button_is_hidden_without_the_privilege
    @request.session[:user_id] = 2
    get :index
    assert_response :success
    assert_select '#agent-add-agent', 0
    # The wrapper carries padding, so it has to go too.
    assert_select '#agent-menu-actions', 0
  end

  def test_ai_page_renders_the_agent_menu_instead_of_the_projects_menu
    @request.session[:user_id] = 1
    get :index

    assert_response :success
    assert_select '#main-menu a[href*="agent_key=query"]', 1
    assert_select '#main-menu a[href="/projects"]', 0
  end

  def test_the_button_shows_for_a_holder
    grant_add_agent(User.find(2))
    @request.session[:user_id] = 2
    get :index
    assert_response :success
    assert_select '#agent-add-agent', 1
  end

  def test_the_button_is_hidden_for_an_admin_without_the_privilege
    @request.session[:user_id] = 1
    assert User.find(1).admin?
    get :index
    assert_response :success
    assert_select '#agent-add-agent', 0
  end

  def test_the_button_shows_for_an_admin_holding_the_privilege
    grant_add_agent(User.find(1))
    @request.session[:user_id] = 1
    get :index
    assert_response :success
    assert_select '#agent-add-agent', 1
  end
end
