module Fragmentary
  class Handler
    def self.all
      @@all
    end

    def self.clear
      @@all = []
    end
    self.clear

    def self.create(**args)
      @@all << (handler = self.new(args))
      handler
    end

    def initialize(**args)
      @args = args
    end

    def call
      raise "Method 'call' not defined."
    end
  end
end

class ActiveRecord::Base
  def to_h
    attributes.symbolize_keys
  end
end
