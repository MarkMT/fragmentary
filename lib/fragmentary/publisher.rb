require 'wisper/active_record'

module Fragmentary

  module Publisher

    def self.included(base)
      base.instance_eval do
        @class_registrations ||= Set.new
        include Wisper.model
        # ensures we override Wisper's definitions
        include InstanceMethods
        extend ClassMethods
      end
    end

    module InstanceMethods

      private

      def registrations
        local_registrations + class_registrations + global_registrations + temporary_registrations
      end

      def class_registrations
        self.class.registrations
      end

      def after_create_broadcast
        Rails.logger.info "\n***** #{start = Time.now} broadcasting :after_create from #{self.class.name} #{self.id}\n"
        broadcast(:after_create, self)
        Rails.logger.info "\n***** #{Time.now} broadcast :after_create from #{self.class.name} #{self.id} took #{(Time.now - start) * 1000} ms\n"
      end

      def after_update_broadcast
        Rails.logger.info "\n***** #{start = Time.now} broadcasting :after_update from #{self.class.name} #{self.id}\n"
        broadcast(:after_update, self) if self.previous_changes.any?
        Rails.logger.info "\n***** #{Time.now} broadcast :after_update from #{self.class.name} #{self.id} took #{(Time.now - start) * 1000} ms\n"
      end

      def after_destroy_broadcast
        broadcast(:after_destroy, self)
      end

      def after_commit_broadcast
      end
    end

    module ClassMethods
      def subscribe(listener, options = {})
        @class_registrations << ::Wisper::ObjectRegistration.new(listener, options.merge(:scope => self))
      end

      def registrations
        @class_registrations + (superclass.try(:registrations) || [])
      end
    end
  end
end


module Wisper
  class ObjectRegistration

    # For the registration to broadcast a specified event we require:
    #   - 'should_broadcast?'    - If the listener susbcribed with an ':on' option, ensure that the event
    #                              is included in the 'on' list.
    #   - 'listener.respond_to?' - The listener contains a handler for the event
    #   - 'publisher_in_scope'   - If the listener subscribed with a ':scope' option, ensure that the
    #                              publisher's class is included in the 'scope' list.
    def broadcast(event, publisher, *args)
      method_to_call = map_event_to_method(event)
      if should_broadcast?(event) && listener.respond_to?(method_to_call) && publisher_in_scope?(publisher)
        broadcaster.broadcast(listener, publisher, method_to_call, args)
      end
    end

    private

    def publisher_in_scope?(publisher)
      allowed_classes.empty? || (allowed_classes.include? publisher.class.name)
    end
  end
end
