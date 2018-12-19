module Fragmentary

  class Config
    include Singleton
    attr_accessor :current_user_method, :get_sign_in_path, :post_sign_in_path, :sign_out_path

    def initialize
      # default
      @current_user_method = :current_user
      @get_sign_in_path = '/users/sign_in'
      @post_sign_in_path = '/users/sign_in'
      @sign_out_path = '/users/sign_out'
    end
  end

  def self.current_user_method
    self.config.current_user_method
  end
end
