desc "Revendor gems"
task :revendor do
  FileUtils.rm_rf(File.join(File.dirname(__FILE__), "vendor"))
  %w{rack sequel taps}.each do |gem|
    system("gem unpack #{gem} --target=vendor")
  end
end

require 'rspec/core/rake_task'

desc 'Run all specs'
RSpec::Core::RakeTask.new(:spec) do |t|
  t.verbose = true
end

task :default => :spec
