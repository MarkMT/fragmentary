module Fragmentary

  class SessionUser

    def self.all
      @@all ||= Hash.new
    end

    def self.fetch(key)
      all[key]
    end

    def initialize(user_type, options={})
      if user = self.class.fetch(user_type)
        if user.options != options
          raise RangeError, "You can't redefine an existing SessionUser object: #{user_type.inspect}"
        else
          user
        end
      else
        @user_type = user_type
        @options = options
        self.class.all.merge!({user_type => self})
      end
    end

    def credentials
      options[:credentials]
    end

    protected
    def options
      @options
    end

  end

end
