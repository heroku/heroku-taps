Dir[File.join(File.expand_path("../vendor", __FILE__), "*")].each do |vendor|
  $:.unshift File.join(vendor, "lib")
end

require("heroku/command/db")
require("#{File.dirname(__FILE__)}/lib/taps/heroku/command/db")
