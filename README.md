# Redmine Agent

The AI Agent plugin for Redmine adds a chat assistant that interacts with your Redmine data using the tools provided by the [Redmine MCP](https://github.com/adhi-software/redmine_mcp) plugin.

## Installation

- Extract the zip file into the `redmine/plugins` directory.

- Run the following command for db migration
  ```sh
  bundle exec rake redmine:plugins:migrate NAME=redmine_agent RAILS_ENV=production

## Uninstallation

- When uninstalling the plugin, be sure to remove the db changes by running
  ```sh
  bundle exec rake redmine:plugins:migrate NAME=redmine_agent VERSION=0 RAILS_ENV=production

## Compatibility Matrix

| **Redmine** | **Redmine Agent** |
|-------------|-------------------|
| 7.0.x | 1.0, 1.0.1 |

## Release Notes for v1.0.1

- **Features**
  ```text
  - Added Rest Api
  ```
- **Bug fixes**
  ```text
   - Fixed agent to work without an MCP server.
  ```
  
## Customization

For any Customization/Support, please contact us, our consulting team will be happy to help you

Adhi Software Pvt Ltd<br>
12/B-35, 6th Cross Road<br>
SIPCOT IT Park, Siruseri<br>
Kancheepuram Dist<br>
Tamilnadu - 603103<br>
India

Website: [https://www.adhisoftware.co.in](https://www.adhisoftware.co.in)<br>
Email: info@adhisoftware.co.in<br>
Phone: +91 44 27470401
