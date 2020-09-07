module Fragmentary

  class RequestQueue

    def self.all
      @@all ||= []
    end

    attr_reader :requests, :user_type, :host_root_url

    def initialize(user_type, host_root_url)
      @user_type = user_type
      # host_root_url represents where the queued *requests* are to be processed. For internal sessions it also represents where
      # the *queue* will be processed by delayed_job. For external requests, the queue will be processed by the host creating the
      # queue and the requests will be explicitly sent to the host_root_url.
      @host_root_url = host_root_url
      @requests = []
      self.class.all << self
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

    def sender
      @sender ||= Sender.new(self)
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

      class AppInstance
        def initialize(url)
          @url = URI.parse(url)
        end

        def queue_name
          to_s.gsub(%r{https?://}, '')
        end

        delegate :host, :port, :path, :scheme, :to_s, :to => :@url
      end

      attr_reader :queue

      def initialize(queue)
        @queue = queue
        @target_instance = AppInstance.new(queue.host_root_url)
      end

      def session_user
        @session_user ||= Fragmentary::SessionUser.fetch(queue.user_type)
      end

      def session
        @session ||= InternalUserSession.new(@target_instance, session_user)
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

      def send_next_request
        if queue.size > 0
          request = queue.next_request
          session.send_request(:method => request.method, :path => request.path, :parameters => request.parameters, :options => request.options)
        end
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
            Delayed::Job.enqueue self, :run_at => delay.from_now, :queue => @target_instance.queue_name
          end
        end
      end

      def clear_session
        @session = nil
      end

    end

  end

end
