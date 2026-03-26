module Fragmentary

  class SessionUser

    attr_reader :options, :user_type

    def self.all
      @@all ||= Hash.new { |hsh, user_type| hsh[user_type] = Hash.new }
    end
    private_class_method :all
    private_class_method :new

    def self.fetch(user_type, user_group = 'default')
      all[user_type][user_group]
    end

    def self.create(user_type, options={})
      user_group = options[:group] || options[:user_group] || 'default'
      if user = fetch(user_type, user_group)
        raise RangeError, "You can't redefine an existing SessionUser object: #{user_type.inspect}" unless user.options == options
      else
        @user_type = user_type   # this probably not really necessary
        @options = options
        user = new(user_type, options)
        all[user_type].merge!(user_group => user)
      end
      user
    end

    def initialize(user_type, options={})
      @user_type = user_type   # this probably not really necessary
      @options = options
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
