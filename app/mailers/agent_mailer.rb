# Core Mailer#process requires the first argument to be a User (sets
# User.current and the recipient's locale for the render).
class AgentMailer < Mailer
  def agent_message(user, subject, body)
    @body_text = body.to_s
    mail to: user, subject: subject
  end
end
