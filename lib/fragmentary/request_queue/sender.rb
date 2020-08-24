module Fragmentary

  class RequestQueue

    class Sender

      class << self
        def jobs
          ::Delayed::Job.where("(handler LIKE ?) OR (handler LIKE ?)", "--- !ruby/object:#{name} %", "--- !ruby/object:#{name}\n%")
        end
      end

      attr_reader :queue

      def initialize(queue)
        @queue = queue
      end

      def session
        @session ||= new_session
      end

      def session_user
        @session_user ||= Fragmentary::SessionUser.fetch(queue.user_type)
      end

      def new_session
        rails "#new_session is not implemented in the RequestQueue::Sender base class"
      end

      # Send all requests, either directly or by schedule
      def start(delay: nil, between: nil)
        Rails.logger.info "\n***** Processing request queue for user_type '#{queue.user_type}'\n"
        @delay = delay; @between = between
        if @delay or @between
          schedule_requests(@delay)
          # sending requests by schedule makes a copy of the sender and queue objects for
          # asynchronous execution, so we have to manually clear out the original queue.
          queue.clear
        else
          send_all_requests
        end
      end

      def perform
        Rails.logger.info "\n***** Processing request queue for user_type '#{queue.user_type}'\n"
        @between ? send_next_request : send_all_requests
      end

      def success
        schedule_requests(@between) if queue.size > 0
      end

      private

      def send_all_requests
        while queue.size > 0
          send_next_request
        end
      end

      def schedule_requests(delay=0.seconds)
        if queue.size > 0
          clear_session
          Delayed::Job.transaction do
            self.class.jobs.destroy_all
            Delayed::Job.enqueue self, :run_at => delay.from_now
          end
        end
      end

      def clear_session
        @session = nil
      end

    end
  end

end
