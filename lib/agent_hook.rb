class AgentHook < Redmine::Hook::ViewListener
	include RedmineAgentHelper

	def get_other_settings(context={})
		settings = context[:configs][:settings]
		context[:configs][:agent_module] = true
		settings['agent_human_in_the_loop'] = Setting.plugin_redmine_agent['human_in_the_loop'].to_s == '1'

		userlanguage = User.current.language
		if userlanguage != 'en'
			languageSet = context[:configs][:languageSet] || {}
			path = "plugins/redmine_agent/config/locales/en.yml"
			File.open(path).each do |line|
				key, value = line.chomp.split(":")
				languageSet[key.strip] = value.strip if value.present?
			end
		end
	end
end
