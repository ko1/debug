require_relative 'lib/debug/version'

Gem::Specification.new do |spec|
  spec.name          = "debug"
  spec.version       = DEBUGGER__::VERSION
  spec.authors       = ["Koichi Sasada"]
  spec.email         = ["ko1@atdot.net"]

  spec.summary       = %q{Renewed debug.rb}
  spec.description   = %q{Renewed debugger and debug functionality}
  spec.homepage      = "https://github.com/ko1/debug"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")

  # spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ko1/debug"

  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions    = ['ext/debug/extconf.rb']
end
