module Fragmentary

  class Request
    attr_reader :method, :path, :options, :parameters

    def initialize(method, path, parameters=nil, options={})
      @method, @path, @parameters, @options = method, path, parameters, options
    end

    def ==(other)
      method == other.method and path == other.path and parameters == other.parameters and options == other.options
    end
  end

end
