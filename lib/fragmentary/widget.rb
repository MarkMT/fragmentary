module Fragmentary

  class Widget
    attr_reader :template, :key, :match

    def self.inherited subclass
      super if defined? super
      @subclasses ||= []
      @subclasses << subclass
    end

    def self.subclasses
      @subclasses ||= []
      @subclasses.inject([]) do |list, subclass|
        list.push(subclass, *subclass.subclasses)
      end
    end

    def initialize(template, key)
      @template = template
      @key = key
      @match = key.match(pattern)
    end

    def pattern
      Regexp.new('^$')
    end

    def _content
      match ? content : nil
    end

    def content
      "Undefined Widget"
    end
  end


  class UserWidget < Widget
    attr_reader :current_user

    def initialize(template, key)
      super
      @current_user = template.respond_to?(:current_user) ? template.current_user : nil
    end

    def _content
      match ? user_content : nil
    end

    def user_content
      current_user ? content : ""
    end
  end

end
