module Fragmentary

  class Subscription

    class Proxy

      # Allow only one proxy per publisher; the proxy is responsible for subscribing
      # to the publisher on behalf of individual subscriptions and calling handlers
      # on each of them whenever the publisher broadcasts.
      @@all = Hash.new do |h, key|
        h[key] = Proxy.new(:publisher => key.constantize)
      end

      attr_reader :publisher

      def self.fetch(key)
        @@all[key]
      end

      def register(subscription)
        subscriptions << subscription if subscription.is_a? Subscription
      end

      ['create', 'update', 'destroy'].each do |event|
        class_eval <<-HEREDOC
          def after_#{event}(record)
            subscriptions.each do |subscription|
              subscription.after_#{event}(record)
            end
          end
        HEREDOC
      end

      private
      def initialize(publisher:)
        @publisher = publisher
        @publisher.subscribe(self)
      end

      def subscriptions
        @subscriptions ||= Set.new
      end

    end

    include ActiveSupport::Callbacks
    define_callbacks :after_destroy

    attr_reader :subscriber
    attr_accessor :record

    def initialize(publisher, subscriber)
      @subscriber = subscriber
      Proxy.fetch(publisher.name).register(self)
    end

    def after_create(record)
      call_method(:"create_#{record.class.model_name.param_key}_successful", record)
    end

    def after_update(record)
      call_method(:"update_#{record.class.model_name.param_key}_successful", record)
    end

    def after_destroy(record)
      # An ActiveSupport::Callbacks :after_destroy callback is set on the eigenclass of each individual
      # subscription in Fragment.set_record_type in order to clean up fragments whose AR records are destroyed.
      run_callbacks :after_destroy do
        @record = record
        call_method(:"destroy_#{record.class.model_name.param_key}_successful", record)
      end
    end

    private
    def call_method(method, record)
      Rails.logger.info "***** Calling #{method.inspect} on #{subscriber.client.name} with record #{record.class.name} #{record.id}"
      start = Time.now
      subscriber.public_send(method, record) if subscriber.respond_to? method
      finish = Time.now
      Rails.logger.info "***** #{method.inspect} duration: #{(finish - start) * 1000}ms\n\n"
    end

  end

end
