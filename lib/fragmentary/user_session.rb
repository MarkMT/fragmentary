require 'rails/console/app'

module Fragmentary

  class UserSession

    include Rails::ConsoleMethods

    attr_reader :session, :user

    def initialize(*user, &block)
      # app is from Rails::ConsoleMethods. It returns an object ActionDispatch::Integration::Session.new(Rails.application)
      # with some extensions. See https://github.com/rails/rails/blob/master/railties/lib/rails/console/app.rb
      # The session object has instance methods get, post etc.
      # See https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/testing/integration.rb
      @session = app
      sign_in if @user = get_user(*user)
      instance_eval(&block) if block_given?
    end

    def method_missing(method, *args)
      session.send(method, *args)
    end

    def sign_out
      post '/users/sign_out', {:_method => 'delete', :authenticity_token => request.session[:_csrf_token]}
    end

    def sign_in
      get "/users/sign_in"  # necessary in order to get the csrf token
      # NOTE: In Rails 5, params is changed to a named argument, i.e. :params => {...}. Will need to be changed.
      post "/users/sign_in", {:user => {:email => user.email, :password => user.try(:password)},
                              :authenticity_token => request.session[:_csrf_token]}
      if session.redirect?
        follow_redirect!
      else
        raise "Sign in failed for user #{user.name} #{user.password}"
      end
    end

    private
    def get_user(*attrs)
      return nil if attrs.nil?
      if (user = attrs.shift).is_a? User and user.password
        user
      elsif user.is_a? String
        User.test_user(user, :admin => attrs.shift.try(:delete, :admin))
      end
    end

  end

end
