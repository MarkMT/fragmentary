module Fragmentary

  module FragmentsHelper

    def cache_fragment(options)
      no_cache = options.delete(:no_cache)
      options.reverse_merge!(:user => Template.new(self).current_user)
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
      options.reverse_merge!(:user => Template.new(template).current_user)
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
        options.reverse_merge!(:user => Template.new(template).current_user)
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


  # Just a wrapper to allow us to call a configurable current_user_method on the template
  class Template
    attr_reader :template

    def initialize(template)
      @template = template
    end

    def current_user
      return nil unless methd = Fragmentary.current_user_method
      if template.respond_to? methd
        template.send methd
      else
        raise NoMethodError, "The current_user_method '#{methd.to_s}' specified doesn't exist"
      end
    end
  end

end
