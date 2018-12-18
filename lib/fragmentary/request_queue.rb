require 'fragmentary/user_session'

module Fragmentary

  class RequestQueue

    @@all = []

    def self.all
      @@all
    end

    attr_reader :requests, :user_type, :sender

    def initialize(user_type)
      @user_type = user_type
      @requests = []
      @sender = Sender.new(self)
      @@all << self
    end

    def <<(request)
      unless @requests.find{|r| r == request}
        @requests << request
      end
      self
    end

    def size
      @requests.size
    end

    def next_request
      @requests.shift
    end

    def clear
      @requests = []
    end

    def remove_path(path)
      requests.delete_if{|r| r.path == path}
    end

    def send(**args)
      sender.start(args)
    end

    def method_missing(method, *args)
      sender.send(method, *args)
    end

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

      def next_request
        queue.next_request.to_proc
      end

      def send_next_request
        if queue.size > 0
          session.instance_exec(&(next_request))
        end
      end

      def send_all_requests
        while queue.size > 0
          send_next_request
        end
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

      def schedule_requests(delay=0.seconds)
        if queue.size > 0
          clear_session
          Delayed::Job.transaction do
            self.class.jobs.destroy_all
            Delayed::Job.enqueue self, :run_at => delay.from_now
          end
        end
      end

      def session
        @session ||= new_session
      end

      def new_session
        case queue.user_type
        when 'signed_in'
          UserSession.new('Bob')
        when 'admin'
          UserSession.new('Alice', :admin => true)
        else
          UserSession.new
        end
      end

      def clear_session
        @session = nil
      end

    end

  end
end
