require 'rails/console/app'
require 'http'
require 'nokogiri'

module Fragmentary

  class InternalUserSession

    include Rails::ConsoleMethods

    def initialize(user=nil, &block)
      # app is from Rails::ConsoleMethods. It returns an object ActionDispatch::Integration::Session.new(Rails.application)
      # with some extensions. See https://github.com/rails/rails/blob/master/railties/lib/rails/console/app.rb
      # The session object has instance methods get, post etc.
      # See https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/testing/integration.rb
      @session = app
      @user = user
      @session.host! session_host
      sign_in if session_credentials
      instance_eval(&block) if block_given?
    end

    def session_host
      @session_host ||= begin
        match = Rails.application.routes.url_helpers.root_url.match(/https?:\/\/([\w\.]*)(:(\d*))?/)
        host, port = match[1], match[3]
        host + (port ? ":#{port}" : "")
      end
    end

    def session_sign_in_path
      @sign_in_path ||= Fragmentary.config.get_sign_in_path
    end

    def session_sign_out_path
      @sign_out_path ||= Fragmentary.config.sign_out_path
    end

    def session_credentials
      return nil unless @user
      @credentials ||= begin
        credentials = @user.credentials
        credentials.is_a?(Proc) ? credentials.call : credentials
      end
    end

    def relative_url_root
      @relative_url_root ||= Rails.application.routes.relative_url_root
    end

    def session_options
      @session_options ||= relative_url_root ? {'SCRIPT_NAME' => relative_url_root} : {}
    end

    def method_missing(method, *args)
      @session.send(method, *args)
    end

    def sign_in
      raise "Can't sign in without user credentials" unless session_credentials
      get session_sign_in_path, nil, session_options  # necessary in order to get the csrf token
      # NOTE: In Rails 5, params is changed to a named argument, i.e. :params => {...}. Will need to be changed.
      # Note that request is called on session, returning an ActionDispatch::Request; request.session is an ActionDispatch::Request::Session
      puts "      * Signing in as #{session_credentials.inspect}"
      post session_sign_in_path, session_credentials.merge(:authenticity_token => request.session[:_csrf_token]), session_options
      if @session.redirect?
        follow_redirect!
      else
        raise "Sign in failed with credentials #{@credentials.inspect}"
      end
    end

    def follow_redirect!
      raise "not a redirect! #{status} #{status_message}" unless redirect?
      if (url = response.location) =~ %r{://}
        destination = URI.parse(url)
        path = destination.query ? "#{destination.path}?#{destination.query}" : destination.path
      end
      path = relative_url_root ? path.gsub(Regexp.new("^#{relative_url_root}"), "") : path
      get(path, nil, session_options)
      status
    end

    def send_request(method:, path:, parameters: nil, options: {})
      if relative_url_root = Rails.application.routes.relative_url_root
        options.merge!('SCRIPT_NAME' => relative_url_root)
      end
      if options.try(:[], :xhr)
        puts "      * Sending xhr request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
        @session.send(:xhr, method, path, parameters, options)
      else
        puts "      * Sending request '#{request.method.to_s} #{request.path}'" + (!request.parameters.nil? ? " with #{request.parameters.inspect}" : "")
        @session.send(method, path, parameters, options)
      end
    end

    def sign_out
      options = relative_url_root ? {'SCRIPT_NAME' => relative_url_root} : {}
      post session_sign_out_path, {:_method => 'delete', :authenticity_token => request.session[:_csrf_token]}, session_options
    end

  end

  class ExternalUserSession

    def initialize(user, root_url)
      @relative_url_root = URI.parse(root_url).path
      @session = HTTP.persistent(root_url)
      @cookie = nil
      @authenticity_token = nil
      sign_in if @credentials = session_credentials(user)
    end

    def send_request(method:, path:, parameters: nil, options: {})
      if options.try(:[], :xhr)
        puts "      * Sending xhr request '#{method.to_s} #{path}'" + (!request.parameters.nil? ? " with #{parameters.inspect}" : "")
      else
        puts "      * Sending request '#{method.to_s} #{path}'" + (!parameters.nil? ? " with #{parameters.inspect}" : "")
      end
      unless path =~ %r{://}
        path = @relative_url_root + path
      end
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
