require 'fragmentary/subscription'

module Fragmentary

  # Each fragment subclass has a unique Subscriber instance responsible for handling subscriptions
  # to publishers. The subscriber is instantiated the first time it is referenced within the subscribe_to
  # method called on the fragment. That method calls a method of the same name on the subscriber, which
  # instantiates a new Subscription for each publisher it subscribes to and executes its block against
  # the subscriber, thus defining handlers for each publisher event of interest on the subscriber,
  # (rather than the fragment). Any other method invoked within a handler is delegated to the client, i.e.
  # the Fragment subclass that the subscriber is responsible for.
  #
  # A separate subscription exists for each combination of publisher and subscriber (and thus Fragment subclass).
  # When a subscription is instantiated for a given publisher, it registers itself with a Subscription::Proxy
  # for that publisher. The proxy, is instantiated the first time it is referenced by a subscription to a
  # particular publisher, and it subscribes on behalf of all its registered subscriptions to Wisper events
  # broadcast by that publisher.
  #
  # The Proxy class contains the methods such as 'after_create', 'after_update' etc that are called automatically
  # by Wisper when the publisher broacdcasts the corresponding events. These methods each invoke methods of the
  # same name on each of proxy's registered subscriptions, and it is these that in turn invoke the methods
  # defined by the subscribe_to blocks on the susbcriber associated with the subscription.
  class Subscriber
    attr_reader :client, :subscriptions

    def initialize(client)
      @client = client
      @subscriptions = Hash.new do |h, key|
        publisher = key.constantize  # Ensures that the model is loaded so that the const below is defined.
        if Object.const_defined?(key) and publisher < ActiveRecord::Base
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
