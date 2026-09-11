require_relative './lib/agent_hook'
require_relative './lib/redmine_agent/app_url'
require_relative './lib/redmine_agent/custom_agents'
require_relative './lib/redmine_agent/runner'
require_relative './lib/redmine_agent/scheduler'

# Keeps LLM/MCP secrets out of production.log; mutated in place — env_config caches this array.
filters = Rails.application.config.filter_parameters
[:api_key, :mcp_token, :agents, :mcp_servers].each { |p| filters << p unless filters.include?(p) }

Rails.application.config.after_initialize do
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
            html = safe_join([html, render(partial: 'redmine_agent/agent_menu_actions')]) if User.current.logged?
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
    # MCP servers the chat can call tools on, pipe-encoded name|url|token|connected.
    # The built-in Redmine one is derived, not stored here.
    'mcp_servers'    => [],
    # Free-text instructions appended to the system prompt of every chat request.
    'instructions'   => "Never expose another user's information to non-admin users.\n" \
                        "Reject all delete requests by default.",
    # When enabled, create/update/delete tool calls require manual user approval.
    'human_in_the_loop' => '1',
    # Agents (name/task/schedule) live in the ai_agents table and their runs in
    # ai_agent_runs — see RedmineAgent::CustomAgents. Nothing agent-shaped is
    # stored here: the settings blob is a single read-modify-write row.
    # A scheduled run acts as the agent's creator, so there is no run-as
    # setting, and the URL it loops back to comes from Settings > General.
  })

  # Top-bar entry
  menu :top_menu, :ai_agent, { controller: 'redmine_agent', action: 'index' },
       caption: :label_agent_top_menu,
       if: Proc.new { User.current.logged? }

  # The left-nav (:agent_menu) itself is populated dynamically at request
  # time by CustomAgents.sync_menu! (see the render_main_menu patch above) —
  # nothing is registered here at boot.
end

Rails.application.config.after_initialize do
  RedmineAgent::Scheduler.start!
  # A Puma cluster forks after this: the worker inherits no threads, and the
  # claim's unique index keeps several workers from doubling up on a run.
  ActiveSupport::ForkTracker.after_fork { RedmineAgent::Scheduler.start! } if defined?(ActiveSupport::ForkTracker)
end
