require 'rake'

spec = eval(File.read(Dir["*.gemspec"].first))

desc "Validate the gemspec"
task :gemspec do
  spec.validate
end

desc "Build gem locally"
task :build do
  Dir["*.gem"].each { |f| File.delete(f) }
  system "gem build #{spec.name}.gemspec"
end

desc "Install gem locally"
task :install => :build do
  system "gem install #{spec.name}-#{spec.version}"
end

desc "Bump version number"
task :version, :version do |t,args|
  args.with_defaults(:version => nil)
  raise "Supply a version: 'rake version[0.1.2]'" unless args[:version]
  file = File.open('lib/rack_multisite.rb'){ |f| f.read }
  old_version = ''
  file.sub!(/VERSION\s*=\s*['"](.+?)['"]/) do |m|
    old_version = $1
    m.sub($1, args[:version])
  end
  File.open('lib/rack_multisite.rb', 'w'){ |f| f.write(file) }
  puts "Bumped version #{old_version} -> #{args[:version]}"
end
