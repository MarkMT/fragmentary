module Fragmentary

  class Config
    include Singleton
    attr_accessor :current_user_method, :get_sign_in_path, :post_sign_in_path, :sign_out_path,
                  :users, :default_user_type_mapping, :session_users, :application_root_url_column,
                  :remote_urls, :insert_timestamps, :deployed_at, :release_name

    def initialize
      # default
      @current_user_method = :current_user
      @application_root_url_column = :application_root_url
      @remote_urls = []
      @insert_timestamps = false
      @deployed_at = nil
      @release_name = nil
    end

    def session_users=(session_users)
      raise "config.session_users must be a Hash" unless session_users.is_a?(Hash)
      Fragmentary.parse_session_users(session_users)
      @session_users = session_users
    end

    def application_root_url_column=(column_name)
      @application_root_url_column = column_name.to_sym
    end
  end

  def self.current_user_method
    self.config.current_user_method
  end

  # Parse a set of session_user options, creating session_users where needed, and return a set of user_type keys.
  # session_users may take several forms:
  #   (1) a hash whose keys are user_type strings and whose values have the form {:credentials => credentials},
  #       where 'credentials' is either a hash of parameters to be submitted when logging in or a proc that
  #       returns those parameters.
  #   (2) an array of hashes as described in (1) above.
  #   (3) an array of user_type strings corresponding to SessionUser objects already defined.
  #   (4) an array containing a mixture of user_type strings and hashes as described in (1) above.
  # Non-hash elements that don't represent existing SessionUser objects should raise an exception. Array
  # elements that are hashes should be parsed to create new SessionUser objects. Raise an exception on
  # any attempt to redefine an existing user_type.
  def self.parse_session_users(session_users = nil)
    return nil unless session_users
    if session_users.is_a?(Array)
      # Fun fact: can't use 'each_with_object' here because 'acc += parse_session_users(v)' would assign
      # a different object to 'acc' on each iteration, while 'each_with_object' passes the *same* object
      # to the block on each iteration.
      session_users.inject([]) do |acc, v|
        if v.is_a?(Hash)
          acc + parse_session_users(v)
        else
          # v is a user_type, e.g. :admin
          raise "No SessionUser exists for user_type '#{v}'" unless SessionUser.fetch(v)
          acc << v
        end
      end
    elsif session_users.is_a?(Hash)
      session_users.each_with_object([]) do |(k,v), acc|
        # k is the user_type, v is an options hash that typically looks like  {:credentials => login_credentials} where
        # login_credentials is either a hash of parameters to be submitted at login or a proc that returns those parameters.
        # In the latter case, the proc is executed when we actually log in to create a new session for the specified user.
        acc << k if user = SessionUser.new(k,v)
      end
    end
  end
end
