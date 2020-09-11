module Fragmentary

  module FragmentsHelper

    def cache_fragment(options, &block)
      options.reverse_merge!(Fragmentary.config.application_root_url_column => self.root_url.gsub(%r{https?://}, ''))
      CacheBuilder.new(self).cache_fragment(options, &block)
    end

    def fragment_builder(options)
      # the template option is deprecated but avoids breaking prior usage
      template = options.delete(:template) || self
      options.reverse_merge!(:user => Template.new(template).current_user)
      CacheBuilder.new(template, Fragmentary::Fragment.base_class.existing(options))
    end

    class CacheBuilder
      include ::ActionView::Helpers::CacheHelper
      include ::ActionView::Helpers::TextHelper

      attr_reader :fragment

      def initialize(template, fragment = nil)
        @fragment = fragment
        @template = template
      end

      def cache_fragment(options, &block)
        no_cache = options.delete(:no_cache)
        insert_widgets = options.delete(:insert_widgets)
        options.reverse_merge!(:user => Template.new(@template).current_user)
        # If the CacheBuilder was instantiated with an existing fragment, next_fragment is its child;
        # otherwise it is the root fragment specified by the options provided.
        next_fragment = @fragment.try(:child, options) || Fragmentary::Fragment.base_class.root(options)
        builder = CacheBuilder.new(@template, next_fragment)
        unless no_cache
          @template.cache next_fragment, :skip_digest => true do
            yield(builder)
          end
        else
          yield(builder)
        end
        @template.output_buffer = WidgetParser.new(@template).parse_buffer if (!@fragment || insert_widgets)
      end

      alias cache_child cache_fragment

      private

      def method_missing(method, *args)
        @fragment.send(method, *args)
      end

    end

  end


  # Just a wrapper to allow us to call a configurable current_user_method on the template
  class Template

    def initialize(template)
      @template = template
    end

    def current_user
      return nil unless methd = Fragmentary.current_user_method
      if @template.respond_to? methd
        @template.send methd
      else
        raise NoMethodError, "The current_user_method '#{methd.to_s}' specified doesn't exist"
      end
    end
  end

end
