module Fragmentary

  class Config
    include Singleton
    attr_accessor :current_user_method

    def initialize
      # default
      @current_user_method = :current_user
    end
  end

  def self.current_user_method
    self.config.current_user_method
  end
end
