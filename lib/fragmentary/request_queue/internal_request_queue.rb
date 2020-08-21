require 'fragmentary/user_session'

module Fragmentary

  class InternalRequestQueue < RequestQueue

    def sender
      @sender ||= Sender.new(self)
    end

    class Sender < RequestQueue::Sender

      def new_session
        puts "***** get new session"
        UserSession.new(session_user)
      end

      def send_next_request
        if queue.size > 0
          request = queue.next_request
          if request.options.try(:[], :xhr)
            puts "      * Sending xhr request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
            session.send(:xhr, request.method, request.path, request.parameters, request.options)
          else
            puts "      * Sending request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
            session.send(request.method, request.path, request.parameters, request.options)
          end
        end
      end

    end

  end

end
