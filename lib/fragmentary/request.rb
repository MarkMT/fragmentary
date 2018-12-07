module Fragmentary

  class Request
    attr_reader :method, :path, :options, :parameters

    def initialize(method, path, parameters=nil, options=nil)
      @method, @path, @parameters, @options = method, path, parameters, options
    end

    def ==(other)
      method == other.method and path == other.path and parameters == other.parameters and options == other.options
    end

    def to_proc
      method = @method; path = @path; parameters = @parameters; options = @options.try :dup
      if @options.try(:[], :xhr)
        Proc.new do
          puts "      * Sending xhr request '#{method.to_s} #{path}'" + (!parameters.nil? ? " with #{parameters.inspect}" : "")
          send(:xhr, method, path, parameters, options)
        end
      else
        Proc.new do
          puts "      * Sending request '#{method.to_s} #{path}'" + (!parameters.nil? ? " with #{parameters.inspect}" : "")
          send(method, path, parameters, options)
        end
      end
    end
  end

end
