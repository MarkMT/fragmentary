require 'fragmentary/user_session'

module Fragmentary

  class InternalRequestQueue < RequestQueue

    def sender
      @sender ||= Sender.new(self)
    end

    class Sender < RequestQueue::Sender

      def new_session
        UserSession.new(session_user)
      end

      def send_next_request
        if queue.size > 0
          request = queue.next_request
          options = request.options
          if relative_url_root = Rails.application.routes.relative_url_root
            options.merge!('SCRIPT_NAME' => relative_url_root)
          end
          if options.try(:[], :xhr)
            puts "      * Sending xhr request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
            session.send(:xhr, request.method, request.path, request.parameters, options)
          else
            puts "      * Sending request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
            session.send(request.method, request.path, request.parameters, options)
          end
        end
      end

    end

  end

end
