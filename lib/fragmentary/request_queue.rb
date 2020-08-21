require 'fragmentary/request_queue/sender'
require 'fragmentary/request_queue/internal_request_queue'
require 'fragmentary/request_queue/external_request_queue'

module Fragmentary

  class RequestQueue

    def self.all
      @@all ||= []
    end

    attr_reader :requests, :user_type

    def initialize(user_type)
      @user_type = user_type
      @requests = []
      self.class.all << self
    end

    def <<(request)
      unless @requests.find{|r| r == request}
        @requests << request
      end
      self
    end

    def size
      @requests.size
    end

    def next_request
      @requests.shift
    end

    def clear
      @requests = []
    end

    def remove_path(path)
      requests.delete_if{|r| r.path == path}
    end

    def send(**args)
      sender.start(args)
    end

    def method_missing(method, *args)
      sender.send(method, *args)
    end

  end

end
