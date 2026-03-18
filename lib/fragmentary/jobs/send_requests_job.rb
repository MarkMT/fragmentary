require 'fragmentary/serializers/request_queue_serializer'

module Fragmentary

  class SendRequestsJob < ActiveJob::Base

    after_perform :schedule_next

    def perform(queue, delay: nil, between: nil, queue_suffix: '', priority: 0)
      @queue = queue
      @delay = delay
      @between = between
      @queue_suffix = queue_suffix
      @priority = priority
      @between ? @queue.send_next_request : @queue.send_all_requests
    end

    def schedule_next
      if @queue.size > 0
        self.enqueue(:wait => @between, :queue => @queue.target.queue_name + @queue_suffix, :priority => @priority)
      end
    end

  end

end
