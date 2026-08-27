# Redmine Agent
# Copyright (C) 2026-  Adhi software pvt ltd
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

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
