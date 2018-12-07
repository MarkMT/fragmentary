
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fragmentary/version"

Gem::Specification.new do |spec|
  spec.name          = "fragmentary"
  spec.version       = Fragmentary::VERSION
  spec.authors       = ["Mark Thomson"]
  spec.email         = ["mark.thomson@persuasivethinking.com"]

  spec.summary       = %q{Fragment modeling and caching for Rails}
  spec.homepage      = "https://github.com/MarkMT/fragmentary"
  spec.license       = "MIT"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "rails", ">= 4.0.0", "< 5"
  spec.add_runtime_dependency "delayed_job_active_record", "~> 4.1"
  spec.add_runtime_dependency "wisper-activerecord", "~> 1.0"
  spec.add_development_dependency "bundler", "~> 1.17"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
