module Fragmentary

  module FragmentsHelper

    def cache_fragment(options)
      no_cache = options.delete(:no_cache)
      options.reverse_merge!(:user => current_user) if respond_to?(:current_user)
      fragment = options.delete(:fragment) || Fragmentary::Fragment.base_class.root(options)
      builder = CacheBuilder.new(fragment, template = self)
      unless no_cache
        cache fragment, :skip_digest => true do
          yield(builder)
        end
      else
        yield(builder)
      end
      self.output_buffer = WidgetParser.new(self).parse_buffer
    end

    def fragment_builder(options)
      template = options.delete(:template)
      options.reverse_merge!(:user => current_user) if respond_to?(:current_user)
      CacheBuilder.new(Fragmentary::Fragment.base_class.existing(options), template)
    end


    class CacheBuilder
      include ::ActionView::Helpers::CacheHelper
      include ::ActionView::Helpers::TextHelper

      attr_accessor :fragment, :template

      def initialize(fragment, template)
        @fragment = fragment
        @template = template
      end

      def cache_child(options)
        no_cache = options.delete(:no_cache)
        insert_widgets = options.delete(:insert_widgets)
        options.reverse_merge!(:user => template.current_user) if template.respond_to?(:current_user)
        child = options.delete(:child) || fragment.child(options)
        builder = CacheBuilder.new(child, template)
        unless no_cache
          template.cache child, :skip_digest => true do
            yield(builder)
          end
        else
          yield(builder)
        end
        template.output_buffer = WidgetParser.new(template).parse_buffer if insert_widgets
      end

      def method_missing(method, *args)
        fragment.send(method, *args)
      end

    end

  end

end
