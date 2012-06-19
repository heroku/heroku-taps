$stdin = File.new("/dev/null")

require "rubygems"

require "heroku"
require "heroku/cli"
require "rspec"
require "fakefs/safe"
require "tmpdir"

require "#{File.dirname(__FILE__)}/../init"

def prepare_command(klass)
  command = klass.new
  command.stub!(:app).and_return("myapp")
  command.stub!(:ask).and_return("")
  command.stub!(:display)
  command.stub!(:hputs)
  command.stub!(:hprint)
  command.stub!(:heroku).and_return(mock('heroku client', :host => 'heroku.com'))
  command
end

RSpec.configure do |config|
  config.color_enabled = true
  config.order = 'rand'
  config.before { Heroku::Helpers.error_with_failure = false }
end

