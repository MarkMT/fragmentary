module Fragmentary

  class Config
    include Singleton
    attr_accessor :current_user_method, :get_sign_in_path, :post_sign_in_path,
                  :sign_out_path, :users, :default_user_type_mapping, :session_users

    def initialize
      # default
      @current_user_method = :current_user
    end

    def session_users=(session_users)
      raise "config.session_users must be a Hash" unless session_users.is_a?(Hash)
      Fragmentary.parse_session_users(session_users)
      @session_users = session_users
    end
  end

  def self.current_user_method
    self.config.current_user_method
  end

  # Parse a class-specific set of session_user options
  # session_users can be an array of session_user keys, a hash of session_user definitions or an array
  # containing a mixture of both. The method should return an array of keys. If session_users is an
  # array, elements representing existing SessionUser objects should be included in the returned array.
  # Non-hash elements that don't represent existing SessionUser objects should raise an exception. Array
  # elements that are hashes should be parsed to create new SessionUser objects. Raise an exception if
  # any attempt to redefine an existing user_type.
  def self.parse_session_users(session_users = nil)
    return nil unless session_users
    if session_users.is_a?(Array)
      # Fun fact: can't use 'each_with_object' here because 'acc += parse_session_users(v)' assigns a
      # different object to 'acc', while 'each_with_object' passes the *same* object to the block on
      # each iteration.
      session_users.inject([]) do |acc, v|
        if v.is_a?(Hash)
          acc + parse_session_users(v)
        else
          acc << v
        end
      end
    elsif session_users.is_a?(Hash)
      session_users.each_with_object([]) do |(k,v), acc|
        acc << k if user = SessionUser.new(k,v)
      end
    end
  end
end
