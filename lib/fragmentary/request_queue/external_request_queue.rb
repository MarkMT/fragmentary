require 'fragmentary/user_session'

module Fragmentary

  class ExternalRequestQueue < RequestQueue

    def initialize(user_type, url)
      @root_url = url
      super(user_type)
    end

    def sender
      @sender ||= Sender.new(self, @root_url)
    end

    class Sender < RequestQueue::Sender

      def initialize(queue, url)
        @root_url = url
        super(queue)
      end

      def new_session
        ExternalUserSession.new(session_user, @root_url)
      end

      def send_next_request
        if queue.size > 0
          request = queue.next_request
          if request.options.try(:[], :xhr)
            puts "      * Sending xhr request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
          else
            puts "      * Sending request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
          end
          session.send_request(:method => request.method, :path => request.path, :parameters => request.parameters, :options => request.options)
        end
      end

    end
  end

end
