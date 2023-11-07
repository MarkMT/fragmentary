module Fragmentary

  class Dispatcher < ActiveJob::Base

    def perform(tasks)
      tasks.each do |task|
        Rails.logger.info "***** Dispatching task for handler class #{task.class.name}"
        task.call
      end
      RequestQueue.all.each do |queue|
        queue.start
      end
    end

  end

end
