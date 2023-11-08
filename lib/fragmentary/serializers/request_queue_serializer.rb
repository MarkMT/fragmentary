module Fragmentary

  class RequestQueueSerializer < ActiveJob::Serializers::ObjectSerializer

    def serialize?(arg)
      arg.is_a? Fragmentary::RequestQueue
    end

    def serialize(queue)
      super(
        {
        :user_type => queue.user_type,
        :host_root_url => queue.host_root_url,
        :requests => queue.requests.map do |r|
          {
          :method => r.method,
          :path => r.path,
          :parameters => r.parameters,
          :opinions => r.options
          }
        end
        }
      )
    end

    def deserialize(hsh)
      queue = RequestQueue.new(hsh[:user_type], hsh[:host_root_url])
      hsh[:requests].each do |r|
        queue << Request.new(r[:method], r[:path], r[:parameters], r[:options] || {})
      end
      queue
    end

  end

end
