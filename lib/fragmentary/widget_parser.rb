module Fragmentary

  class WidgetParser

    include ActionView::Helpers::JavaScriptHelper

    attr_reader :template, :current_user, :widget_container

    def initialize(template)
      @template = template
      @widget_container = {:'' => 'Empty widget specification detected'}
    end

    # This method returns a new OutputBuffer instance that can be used to overwrite the existing
    # template's output_buffer with a copy that has its widget specifications expanded. It is
    # usually called from cache_fragment to insert widgets into a cached root fragment. However
    # when an ajax request inserts a non-root fragment into a page it can be invoked from
    # CacheBuilder#cache_child if that method is called with the :insert_widgets option set to
    # true. Alternatively if an ajax request inserts content containing a widget without a fragment
    # context, i.e. in order to modify content *within* a fragment, a WidgetParser can be
    # instantiated separately using erb at the end of the view template. This can be done either
    # in an html template if the client is loading html by ajax (e.g. jQuery.load) or in a js(.coffee)
    # script if the ajax request loads javascript.
    def parse_buffer(options = {})
      template.output_buffer.scan(/%{([^}]+)}/) do |spec|
        widget_key = spec[0]; widget = nil
        widget_container[widget_key.to_sym] = if Widget.subclasses.find{|klass| (widget = klass.new(template, widget_key)).match}
          if options[:javascript] or options[:js]
            escape_javascript(widget._content)
          else
            widget._content
          end
        else
          "Oops! Widget not found."
        end
      end
      # The gsub replaces instances of '%' that aren't part of widget specifications with '%%', preventing
      # those characters from making the buffer an invalid format specification. The substitution operation
      # restores them to single characters. The new OutputBuffer is needed because gsub returns a string.
      # (Although gsub! would return an OutputBuffer if a substitution occurs, it returns nil otherwise,
      # so isn't suitable here.)
      ActionView::OutputBuffer.new(template.output_buffer.gsub(/%(?!{)/,'%%') % widget_container)
    end
  end

end
