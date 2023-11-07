module Fragmentary

  class HandlerSerializer < ActiveJob::Serializers::ObjectSerializer

    def serialize?(arg)
      arg.is_a? Fragmentary::Handler
    end

    def serialize(handler)
      super(
        {
        :class_name => handler.class.name,
        :args => handler.args
        }
      )
    end

    def deserialize(hsh)
      hsh[:class_name].constantize.new(hsh[:args])
    end

  end

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

    attr_reader :args

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
