require 'rails/console/app'
require 'http'
require 'nokogiri'

module Fragmentary

  class UserSession

    include Rails::ConsoleMethods

    def initialize(user, &block)
      puts "***** instantiate session"
      # app is from Rails::ConsoleMethods. It returns an object ActionDispatch::Integration::Session.new(Rails.application)
      # with some extensions. See https://github.com/rails/rails/blob/master/railties/lib/rails/console/app.rb
      # The session object has instance methods get, post etc.
      # See https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/testing/integration.rb
      @session = app
      @credentials = session_credentials(user)
      puts "***** credentials #{@credentials.inspect}"
      sign_in if @credentials
      instance_eval(&block) if block_given?
    end

    def session_credentials(user)
      credentials = user.try(:credentials)
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
      # Note that request is called on session, returning an ActionDispatch::Request; request.session is an ActionDispatch::Request::Session
      puts "      * Signing in as #{@credentials.inspect}"
      post Fragmentary.config.post_sign_in_path, @credentials.merge(:authenticity_token => request.session[:_csrf_token])
      if @session.redirect?
        follow_redirect!
      else
        raise "Sign in failed with credentials #{@credentials.inspect}"
      end
    end

  end

  class ExternalUserSession

    def initialize(user, application_root_path = 'https://persuasivethinking.com')
      @session = HTTP.persistent(application_root_path)
      @cookie = nil
      @authenticity_token = nil
      sign_in if @credentials = session_credentials(user)
    end

    def send_request(method:, path:, parameters: nil, options: {})
      cookies = @cookie ? {@cookie.name.to_sym => @cookie.value} : {}
      headers = options.try(:delete, :headers) || {}
      headers.merge!({:'X-Requested-With' => 'XMLHttpRequest'}) if options.try(:delete, :xhr)
      response = @session.cookies(cookies).headers(headers).send(method, path, {:json => parameters})
      @cookie = response.cookies.first
      @authenticity_token = Nokogiri::HTML.parse(response.to_s).css('head meta[name="csrf-token"]').first.try(:[], 'content')
      if (response.code >=300) && (response.code <=399)
        location = response.headers[:location]
        options = {:headers => {:accept => "text/html,application/xhtml+xml,application/xml"}}
        response = send_request(:method => :get, :path => location, :parameters => nil, :options => options)
      end
      response
    end

    def session_credentials(user)
      credentials = user.try(:credentials)
      credentials.is_a?(Proc) ? credentials.call : credentials
    end

    def sign_in
      # The first request retrieves the authentication token
      response = send_request(:method => :get, :path => Fragmentary.config.get_sign_in_path)
      puts "      * Signing in as #{@credentials.inspect}"
      response = send_request(:method => :post, :path => Fragmentary.config.post_sign_in_path,
                              :parameters => @credentials.merge(:authenticity_token => @authenticity_token),
                              :options => {:headers => {:accept => "text/html,application/xhtml+xml,application/xml"}})
    end

    def sign_out
      send_request(:method => :delete, :path => Fragmentary.config.sign_out_path, :parameters => {:authenticity_token => @authenticity_token})
      @session.close
    end
  end

end
