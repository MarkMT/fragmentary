require 'rails/console/app'

module Fragmentary

  class UserSession

    include Rails::ConsoleMethods

    def initialize(user, &block)
      # app is from Rails::ConsoleMethods. It returns an object ActionDispatch::Integration::Session.new(Rails.application)
      # with some extensions. See https://github.com/rails/rails/blob/master/railties/lib/rails/console/app.rb
      # The session object has instance methods get, post etc.
      # See https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/testing/integration.rb
      @session = app
      sign_in if @credentials = session_credentials(user)
      instance_eval(&block) if block_given?
    end

    def session_credentials(user)
      credentials = user.try(:[], :credentials)
      credentials.is_a?(Proc) ? credentials.call : credentials
    end

    def method_missing(method, *args)
      @session.send(method, *args)
    end

    def sign_out
      post Fragmentary.config.sign_out_path, {:_method => 'delete', :authenticity_token => request.session[:_csrf_token]}
    end

    def sign_in
      get Fragmentary.config.get_sign_in_path  # necessary in order to get the csrf token
      # NOTE: In Rails 5, params is changed to a named argument, i.e. :params => {...}. Will need to be changed.
      post Fragmentary.config.post_sign_in_path, @credentials.merge(:authenticity_token => request.session[:_csrf_token])
      if @session.redirect?
        follow_redirect!
      else
        raise "Sign in failed with credentials #{@credentials.inspect}"
      end
    end

  end

end
