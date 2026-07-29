get    'redmine_agent',         to: 'redmine_agent#index'
get    'redmine_agent/agents',  to: 'redmine_agent#agents'
post   'redmine_agent/chat',    to: 'redmine_agent#chat_request'
post   'redmine_agent/test_model', to: 'redmine_agent#test_model'
get    'redmine_agent/history', to: 'redmine_agent#history'
delete 'redmine_agent/clear',   to: 'redmine_agent#clear'


