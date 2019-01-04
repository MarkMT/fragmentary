module Fragmentary

  class Widget
    attr_reader :template, :match

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
      @match = key.match(pattern)
    end

    def pattern
      Regexp.new('^$')
    end

    def _content
      match ? content : nil
    end

    private

    def content
      "Undefined Widget"
    end
  end


  class UserWidget < Widget
    attr_reader :current_user

    def initialize(template, key)
      super
      @current_user = Fragmentary::Template.new(template).current_user
    end

    def _content
      match ? user_content : nil
    end

    private

    def user_content
      current_user ? content : ""
    end
  end

end
