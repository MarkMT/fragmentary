require 'fragmentary/subscription'

module Fragmentary

  # Each fragment subclass has a unique Subscriber instance reponsible for handling subscriptions
  # to publishers. Each subscriber maintains a hash of Subscriptions, one for each publisher it
  # subscribes to. The 'subscribe_to' method instantiates each new Subscription in turn and executes
  # its block against against the Subscriber in order to define handlers for each publisher event
  # of interest. Any other method invoked within a handler is delegated to the client, i.e. the
  # fragment subclass that the subscriber is reponsible for.
  class Subscriber
    attr_reader :client, :subscriptions

    def initialize(client)
      @client = client
      @subscriptions = Hash.new do |h, key|
        if Object.const_defined?(key) and (publisher = key.constantize) < ActiveRecord::Base
          h[key] = Subscription.new(publisher, self)
        else
          nil
        end
      end
    end

    def subscribe_to(publisher, block)
      if subscriptions[publisher.name]
        mod = Module.new
        mod.module_exec(&block)
        self.extend mod
      end
    end

    def method_missing(method, *args)
      @client.send(method, *args)
    end
  end

end
