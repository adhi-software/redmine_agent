require_relative './lib/agent_hook'
require_relative './lib/redmine_agent/custom_agents'
require_relative './lib/redmine_agent/setting_patch'
require_relative './lib/redmine_agent/slack_notifier'
require_relative './lib/redmine_agent/email_notifier'
require_relative './lib/redmine_agent/delivery'
require_relative './lib/redmine_agent/runner'
require_relative './lib/redmine_agent/scheduler'

Rails.application.config.after_initialize do
  RedmineAgent::SettingPatch.apply!

  # ERPmine overrides render_main_menu but introduces a bug: it ignores the
  # controller.current_menu and hardcodes its own menu_name() logic.
  # We patch render_main_menu to force it to render our :agent_menu when
  # on the redmine_agent controller, bypassing ERPmine's logic entirely.
  #
  # This is also the one choke point that renders the agent sidebar, so it is
  # where the agent list gets reconciled against the data store on every
  # request (CustomAgents.sync_menu!) — that is what makes a newly created
  # agent show up immediately, in every app worker process, with no restart.
  if defined?(Redmine::MenuManager::MenuHelper)
    Redmine::MenuManager::MenuHelper.module_eval do
      unless method_defined?(:_org_render_main_menu_agent)
        alias_method :_org_render_main_menu_agent, :render_main_menu

        def render_main_menu(project)
          if params[:controller] == 'redmine_agent'
            RedmineAgent::CustomAgents.sync_menu!
            html = render_menu(:agent_menu, project)
            html = safe_join([html, render(partial: 'redmine_agent/agent_menu_actions')]) if User.current.admin?
            html
          else
            _org_render_main_menu_agent(project)
          end
        end
      end
    end
  end
end

Redmine::Plugin.register :redmine_agent do
  name 'Redmine Agent'
  author 'Adhi Software Pvt Ltd'
  description 'Redmine Agent'
  version '1.0.1'
  url ''
  author_url 'http://www.adhisoftware.co.in/'
  requires_redmine version_or_higher: '6.0.0'

  settings(partial: 'settings/redmine_agent_settings', default: {
    # List of configured agents.
    'agents'         => [],
    # Free-text instructions appended to the system prompt of every chat request.
    'instructions'   => "Never expose another user's information to non-admin users.\n" \
                        "Reject all delete requests by default.",
    # When enabled, create/update/delete tool calls require manual user approval.
    'human_in_the_loop' => '1',
    # Custom agents: name/task/schedule/notify, plus a one-time seed flag.
    # See RedmineAgent::CustomAgents. Run history lives in the agent_runs
    # table, not here — it is written on every run, which the settings blob
    # is the wrong shape for.
    'custom_agents'        => [],
    'custom_agents_seeded' => '0',
    # Scheduler: Slack bot token, the user whose API key runs scheduled chats,
    # and the base URL the scheduler loops back to.
    'slack_bot_token'      => '',
    'run_as_login'         => 'admin',
    'base_url'             => '',
    'email_subject_prefix' => '[Redmine Agent]',
  })

  # Top-bar entry
  menu :top_menu, :ai_agent, { controller: 'redmine_agent', action: 'index' },
       caption: :label_redmine_agent,
       if: Proc.new { User.current.logged? }

  # The left-nav (:agent_menu) itself is populated dynamically at request
  # time by CustomAgents.sync_menu! (see the render_main_menu patch above) —
  # nothing is registered here at boot.
end

Rails.application.config.after_initialize do
  RedmineAgent::Scheduler.start!
end
