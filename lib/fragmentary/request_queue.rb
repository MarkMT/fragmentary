module Fragmentary

  class RequestQueue

    def self.all
      @@all ||= []
    end

    def self.send_all(between: nil)
      unless between
        all.each{|q| q.start}
      else
        unless between.is_a? ActiveSupport::Duration
          raise TypeError, "Fragmentary::RequestQueue.send_all requires the keyword argument :between to be of class ActiveSupport::Duration. The value provided is of class #{between.class.name}."
        end
        delay = 0.seconds
        all.each{|q| q.start(:delay => delay += between)}
      end
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

      class Target

        attr_reader :url

        def initialize(url)
          @url = url
        end

        def queue_name
          @url.gsub(%r{https?://}, '')
        end

      end

      attr_reader :queue, :target, :delay, :between, :queue_suffix, :priority

      def initialize(queue)
        @queue = queue
        @target = Target.new(queue.host_root_url)
      end

      def session_user
        @session_user ||= Fragmentary::SessionUser.fetch(queue.user_type)
      end

      def session
        @session ||= InternalUserSession.new(@target.url, session_user)
      end

      # Send all requests, either directly or by schedule
      def start(delay: nil, between: nil, queue_suffix: '', priority: 0)
        Rails.logger.info "\n***** Processing request queue for user_type '#{queue.user_type}'\n"
        @delay = delay; @between = between; @queue_suffix = queue_suffix; @priority = priority
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
          parameters = (request.parameters || {}).merge(:queue_suffix => queue_suffix)
          session.send_request(:method => request.method, :path => request.path, :parameters => parameters, :options => request.options)
        end
      end

      private

      def send_all_requests
        clear_session
        while queue.size > 0
          send_next_request
        end
      end

      def schedule_requests(delay=0.seconds)
        if queue.size > 0
          clear_session
          job = SendRequestsJob.new(queue, delay: delay, between: between, queue_suffix: queue_suffix, priority: priority)
          job.enqueue(:wait => delay, :queue => target.queue_name + queue_suffix, :priority => priority)
        end
      end

      def clear_session
        @session = nil
      end

    end

  end

end
