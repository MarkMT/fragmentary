require 'fragmentary/serializers/handler_serializer'

module Fragmentary

  class DispatchHandlersJob < ActiveJob::Base

    def perform(tasks)
      tasks.each do |task|
        Rails.logger.info "\n***** Dispatching task for handler class #{task.class.name}"
        task.call
      end
      delay = 0.seconds
      RequestQueue.all.each do |queue|
        queue.start(:delay => delay += 10.seconds, :priority => 10)
      end
    end

  end

end
