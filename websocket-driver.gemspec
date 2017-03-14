Gem::Specification.new do |s|
  s.name              = 'websocket-driver'
  s.version           = '0.6.4'
  s.summary           = 'WebSocket protocol handler with pluggable I/O'
  s.author            = 'James Coglan'
  s.email             = 'jcoglan@gmail.com'
  s.homepage          = 'http://github.com/faye/websocket-driver-ruby'
  s.license           = 'MIT'

  s.extra_rdoc_files  = %w[README.md]
  s.rdoc_options      = %w[--main README.md --markup markdown]
  s.require_paths     = %w[lib]

  files = %w[README.md LICENSE.md CHANGELOG.md] +
          Dir.glob('{examples,lib}/**/*.rb')

  if RUBY_PLATFORM =~ /java/
    files += Dir.glob('ext/**/*.java')
  else
    files += Dir.glob('ext/**/*.{c,h,rb}')
    s.extensions << 'ext/websocket_driver/extconf.rb'
  end

  s.files = files

  s.add_dependency 'websocket-extensions', '>= 0.1.0'

  s.add_development_dependency 'benchmark-ips'
  s.add_development_dependency 'eventmachine'
  s.add_development_dependency 'permessage_deflate'
  s.add_development_dependency 'rake-compiler', '~> 0.8.0'
  s.add_development_dependency 'rspec'

  version = RUBY_VERSION.split('.').map { |s| s.to_i }
  if version[0] > 2 or (version[0] == 2 and version[1] >= 1)
    s.add_development_dependency 'memory_profiler'
  end
end
