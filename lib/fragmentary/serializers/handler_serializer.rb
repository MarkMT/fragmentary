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

end
