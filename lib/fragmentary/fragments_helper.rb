module Fragmentary

  module FragmentsHelper

    def cache_fragment(options, &block)
      options.reverse_merge!(Fragmentary.config.application_root_url_column => Fragmentary.application_root_url.gsub(%r{https?://}, ''))
      CacheBuilder.new(self).cache_fragment(options, &block)
    end

    def fragment_builder(options)
      # the template option is deprecated but avoids breaking prior usage
      template = options.delete(:template) || self
      options.reverse_merge!(:user => Template.new(template).current_user)
      options.reverse_merge!(Fragmentary.config.application_root_url_column => application_root_url)
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
            if Fragmentary.config.insert_timestamps
              @template.safe_concat("<!-- #{next_fragment.type} #{next_fragment.id} cached by Fragmentary version #{VERSION} at #{Time.now.utc} -->")
              if deployed_at && release_name
                @template.safe_concat("<!-- Cached using application release #{release_name} deployed at #{deployed_at} -->")
              end
              yield(builder)
              @template.safe_concat("<!-- #{next_fragment.type} #{next_fragment.id} ends -->")
            else
              yield(builder)
            end
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

      def deployed_at
        @deployed_at ||= Fragmentary.config.deployed_at
      end

      def release_name
        @release_name ||= Fragmentary.config.release_name
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
