$: << (File.dirname(__FILE__))
require 'lib/rack/multisite'

spec = Gem::Specification.new do |s|
  s.name = 'rack-multisite'
  s.version = Rack::Multisite::VERSION
  s.summary = 'Low-RAM domain-based routing for rack, with reloading'
  s.description = 'Allows one rack server to serve multiple sites. Sites shut down after a period of non-use, and can be reloaded easily.'
  s.platform = Gem::Platform::RUBY
  s.authors = ['Antony Male']
  s.email = 'antony dot mail at gmail'
  s.required_ruby_version = '>= 1.9.2'
  s.homepage = 'https://github.com/canton7/rack-multisite'

  s.add_dependency 'rack'

  s.files = Dir['lib/**/*']

end
