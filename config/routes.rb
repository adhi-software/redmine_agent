get    'redmine_agent',         to: 'redmine_agent#index'
get    'redmine_agent/agents',  to: 'redmine_agent#agents'
post   'redmine_agent/chat',    to: 'redmine_agent#chat_request'
post   'redmine_agent/test_model', to: 'redmine_agent#test_model'
post   'redmine_agent/test_mcp_server', to: 'redmine_agent#test_mcp_server'
get    'redmine_agent/history', to: 'redmine_agent#history'
delete 'redmine_agent/clear',   to: 'redmine_agent#clear'

get    'redmine_agent/custom_agents',              to: 'redmine_agent#custom_agents'
post   'redmine_agent/custom_agents',              to: 'redmine_agent#create_agent'
patch  'redmine_agent/custom_agents/:key',         to: 'redmine_agent#update_agent'
delete 'redmine_agent/custom_agents/:key',         to: 'redmine_agent#destroy_agent'
post   'redmine_agent/custom_agents/:key/run',     to: 'redmine_agent#run_agent'


