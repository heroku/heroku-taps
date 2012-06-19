desc "Revendor latest version of taps"
task :revendor do
  FileUtils.rm_rf(File.join(File.dirname(__FILE__), 'vendor'))
  system('git clone https://github.com/ricardochimal/taps vendor/taps')
  Dir[File.join(File.dirname(__FILE__), 'vendor', 'taps', '**', '.git')].each do |dir|
    FileUtils.rm_rf(dir)
  end
end
