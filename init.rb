require_relative './lib/agent_hook'

Rails.application.config.after_initialize do
  # ERPmine overrides render_main_menu but introduces a bug: it ignores the
  # controller.current_menu and hardcodes its own menu_name() logic.
  # We patch render_main_menu to force it to render our :agent_menu when
  # on the redmine_agent controller, bypassing ERPmine's logic entirely.
  if defined?(Redmine::MenuManager::MenuHelper)
    Redmine::MenuManager::MenuHelper.module_eval do
      unless method_defined?(:_org_render_main_menu_agent)
        alias_method :_org_render_main_menu_agent, :render_main_menu
        
        def render_main_menu(project)
          if params[:controller] == 'redmine_agent'
            render_menu(:agent_menu, project)
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
  version '1.0'
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
    'human_in_the_loop' => '0',
  })

  # Top-bar entry
  menu :top_menu, :ai_agent, { controller: 'redmine_agent', action: 'index' },
       caption: :label_redmine_agent,
       if: Proc.new { User.current.logged? }

  # Dedicated left-nav menu — only "Redmine Agent", no other Redmine items
  Redmine::MenuManager.map :agent_menu do |menu|
    menu.push :ai_agent_query,
              { controller: 'redmine_agent', action: 'index' },
              caption: :label_agent_query
  end
end
