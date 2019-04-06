module Fragmentary

  module Fragment

    def self.base_class
      @base_class
    end

    def self.included(base)

      @base_class = base

      base.class_eval do
        include ActionView::Helpers::CacheHelper

        belongs_to :parent, :class_name => name
        belongs_to :root, :class_name => name
        has_many :children, :class_name => name, :foreign_key => :parent_id, :dependent => :destroy
        belongs_to :user

        # Don't touch the parent when we create the child - the child was created by
        # renderng the parent, which occured because the parent was touched, thus
        # triggering the current request. Touching it again would result in a
        # redundant duplicate request.
        after_commit :touch_parent, :on => [:update, :destroy]

        attr_accessible :parent_id, :root_id, :record_id, :user_id, :user_type, :key

        attr_accessor :indexed_children

        validate :root_id, :presence => true

        self.cache_timestamp_format = :usec  # Probably not needed for Rails 5, which uses :usec by default.

      end

      base.instance_eval do
        class << self; attr_writer :record_type, :key_name; end
      end

      base.extend ClassMethods

      ActionView::Base.send :include, FragmentsHelper
    end


    # Class Methods
    # -------------
    module ClassMethods

      def root(options)
        if fragment = options[:fragment]
          raise ArgumentError, "You passed Fragment #{fragment.id} to Fragment.root, but it's a child of Fragment #{fragment.parent_id}" if fragment.parent_id
        else
          klass, search_attributes, options = base_class.attributes(options)
          fragment = klass.where(search_attributes).includes(:children).first_or_initialize(options); fragment.save if fragment.new_record?
          fragment.set_indexed_children if fragment.child_search_key
        end
        fragment
      end

      # Each fragment record is unique by type and parent_id (which is nil for a root_fragment) and for some types also by
      # record_id (i.e. for root fragments for pages associated with particular AR records and for child fragments that
      # appear in a list) user_type (e.g. "admin", "signed_in", "signed_out") and user_id (for fragments that include
      # user-specific content).
      def attributes(options)
        klass = options.delete(:type).constantize

        # Augment the options with the user_type and user_id in case they are needed below
        options.reverse_merge!(:user_type => klass.user_type(user = options.delete(:user)), :user_id => user.try(:id))

        # Collect the attributes to be used when searching for an existing fragment. Fragments are unique by these values.
        search_attributes = {}

        parent_id = options.delete(:parent_id)
        search_attributes.merge!(:parent_id => parent_id) if parent_id

        [:record_id, :user_id, :user_type, :key].each do |attribute_name|
          if klass.needs?(attribute_name)
            option_name = (attribute_name == :key and klass.key_name) ? klass.key_name : attribute_name
            attribute = options.delete(option_name) {puts caller(0); raise ArgumentError, "Fragment type #{klass} needs a #{option_name.to_s}"}
            attribute = attribute.try :to_s if attribute_name == :key
            search_attributes.merge!(attribute_name => attribute)
          end
        end

        # If :user_id or :user_name aren't required, don't include them when we create a new fragment record.
        options.delete(:user_id); options.delete(:user_type)

        return klass, search_attributes, options
      end

      def cache_store
        @@cache_store ||= Rails.application.config.action_controller.cache_store
      end

      # ToDo: combine this with Fragment.root
      def existing(options)
        if fragment = options[:fragment]
          raise ArgumentError, "You passed Fragment #{fragment.id} to Fragment.existing, but it's a child of Fragment #{fragment.parent_id}" if fragment.parent_id
        else
          options.merge!(:type => name) unless self == base_class
          raise ArgumentError, "A 'type' attribute is needed in order to retrieve a fragment" unless options[:type]
          klass, search_attributes, options = base_class.attributes(options)
          # We merge options because it may include :record_id, which may be needed for uniqueness even
          # for classes that don't 'need_record_id' if the parent_id isn't available.
          fragment = klass.where(search_attributes.merge(options)).includes(:children).first
          # Unlike Fragment.root and Fragment#child we don't instantiate a record if none is found,
          # so fragment may be nil.
          fragment.try :set_indexed_children if fragment.try :child_search_key
        end
        fragment
      end

      def fragment_type
        self
      end

      def request_queues
        @@request_queues ||= Hash.new do |hash, user_type|
          hash[user_type] = RequestQueue.new(user_type)
        end
        if self == base_class
          @@request_queues
        else
          return nil unless (requestable? or new.requestable?)
          user_types.each_with_object({}){|user_type, queues| queues[user_type] = @@request_queues[user_type]}
        end
      end

      def remove_queued_request(user:, request_path:)
        request_queues[user_type(user)].remove_path(request_path)
      end

      def subscriber
        @subscriber ||= Subscriber.new(self)
      end

      def needs?(attribute_name)
        attribute_name = attribute_name.to_s if attribute_name.is_a? Symbol
        raise ArgumentError unless attribute_name.is_a? String
        send :"needs_#{attribute_name.to_s}?"
      end

      # If a class declares 'needs_user_id', a user_id value must be provided in the attributes hash in order to either
      # create or retrieve a Fragment of that class. A user_id is needed for example when caching user-specific content
      # such as a user profile. When the fragment is instantiated using FragmentsHelper methods 'cache_fragment' or
      # 'CacheBuilder.cache_child', a :user option is added to the options hash automatically from the value of 'current_user'.
      # The user_id is extracted from this option in Fragment.find_or_create.
      def needs_user_id
        self.extend NeedsUserId
      end

      # If a class declares 'needs_user_type', a user_type value must be provided in the attributes hash in order to either
      # create or retrieve a Fragment of that class. A user_type is needed to distinguish between fragments that are rendered
      # differently depending on the type of user, e.g. to distinguish between content seen by signed in users and those not
      # signed in. When the fragment is instantiated using FragmentsHelper methods 'cache_fragment' or 'CacheBuilder.cache_child',
      # a :user option is added to the options hash automatically from the value of 'current_user'. The user_type is extracted
      # from this option in Fragment.find_or_create.
      def needs_user_type(options = {})
        self.extend NeedsUserType
        instance_eval do
          @user_type_mapping = options[:user_type_mapping]
          def self.user_type(user)
            (@user_type_mapping || Fragmentary.config.default_user_type_mapping).try(:call, user)
          end
          @user_types = Fragmentary.parse_session_users(options[:session_users] || options[:types] || options[:user_types])
          def self.user_types
            @user_types || Fragmentary.config.session_users.keys
          end
        end
      end

      def needs_key(options = {})
        extend NeedsKey
        if name = options.delete(:name) || options.delete(:key_name)
          self.key_name = name.to_sym
          define_method(key_name) {send(:key)}
        end
      end

      def key_name
        @key_name ||= nil
      end

      # If a class declares 'needs_record_id', a record_id value must be provided in the attributes hash in order to either
      # create or retrieve a Fragment of that class. Ordinarily a record_id is passed automatically from a parent fragment
      # to its child. However if the child fragment class is declared with 'needs_record_id' the parent's record_id is not
      # passed on and must be provided explicitly, typically for Fragment classes that represent items in a list that
      # each correspond to a particular record of some ActiveRecord class. In these cases the record_id should be provided
      # explicitly in the call to cache_fragment (for a root fragment) or cache_child (for a child fragment).
      def needs_record_id(options = {})
        self.extend NeedsRecordId
        if record_type = options.delete(:record_type) || options.delete(:type)
          set_record_type(record_type)
        end
      end

      def record_type
        raise ArgumentError, "The #{self.name} class has no record_type" unless @record_type
        @record_type
      end

      # A subclass of a class declared with 'needs_record_id' will not have a record_type unless set explicitly, which can be done
      # using the following method.
      def set_record_type(type)
        if needs_record_id?
          self.record_type = type
          if record_type_subscription = subscriber.subscriptions[record_type]
            # Set a callback on the eigenclass of an individual subscription to clean up client fragments
            # corresponding to a destroyed AR record. Note that this assumes that ALL fragments of a class
            # that calls this method should be removed if those fragments have a record_id matching the id
            # of the destroyed AR record. Also note that the call 'subscriber.subscriptions' above ensures that
            # the subscription exists even if the particular fragment subclass doesn't explicitly subscribe
            # to the record_type AR class. And note that if the fragment subclass does subscribe to the
            # record_type class, the callback doesn't affect the execution of any delete handler defined
            # by the fragment.
            class << record_type_subscription
              set_callback :after_destroy, :after, ->{subscriber.client.remove_fragments_for_record(record.id)}
            end
          end

          if requestable?
            record_class = record_type.constantize
            instance_eval <<-HEREDOC
              subscribe_to #{record_class} do
                def create_#{record_class.model_name.param_key}_successful(record)
                  request = Fragmentary::Request.new(request_method, request_path(record.id),
                                                     request_parameters(record.id), request_options)
                  queue_request(request)
                end
              end
            HEREDOC
          end

          define_method(:record){record_type.constantize.find(record_id)}
        end
      end

      def remove_fragments_for_record(record_id)
        where(:record_id => record_id).each(&:destroy)
      end

      def needs_record_id?
        false
      end

      def needs_user_id?
        false
      end

      def user_types
        ['signed_in']
      end

      # This default definition can be overridden by sub-classes as required
      # (typically in root fragment classes by calling needs_user_type).
      def user_type(user)
        user ? "signed_in" : "signed_out"
      end

      def needs_user_type?
        false
      end

      def needs_key?
        false
      end

      # Note that fragments matching the specified attributes won't always exist, e.g. if the page they are to appear on
      # hasn't yet been requested, e.g. an assumption created on an article page won't necessarily have been rendered on the
      # opinion analysis page.
      def touch_fragments_for_record(record_id)
        fragments_for_record(record_id).each(&:touch)
      end

      def fragments_for_record(record_id)
        self.where(:record_id => record_id)
      end

      def subscribe_to(publisher, &block)
        subscriber.subscribe_to(publisher, block)
      end

      def child_search_key
        nil
      end

      def queue_request(request=nil)
        if request
          request_queues.each{|key, queue| queue << request}
        end
      end

      def requestable?
        respond_to?(:request_path)
      end

      # The instance method 'request_method' is defined in terms of this.
      def request_method
        :get
      end

      def request_parameters(*args)
        nil
      end

      # The instance method 'request_options' is defined in terms of this.
      def request_options
        nil
      end

      # This method defines the handler for the creation of new list items. The method takes:
      #   - members: a symbol representing the association class whose records define membership
      #     of the list,
      #   - list_record: an association that when applied to a membership record identifies the record_id
      #     associated with the list itself. This can be specified in the form of a symbol representing
      #     a method to be applied to the membership association or a proc that takes the membership
      #     association as an argument.
      def acts_as_list_fragment(members:, list_record:, **options)
        # The name of the association that defines elements of the list
        @members = members.to_s.singularize
        # And the corresponding class
        @membership_class = @members.classify.constantize
        # A method (in the form of a symbol) or proc that returns the id of the record that identifies
        # the list fragment instance for a given member.
        @list_record = list_record

        # Identifies the record_ids of list fragments associated with a specific membership association.
        # This method will be called from the block passed to 'subscribe_to' below, which is executed
        # against the Subscriber, but sends missing methods back to its client, which is this class.
        # A ListFragment is not declared with 'needs_record_id'; by default it receives its record_id
        # from its parent fragment.
        def list_record(association)
          if @list_record.is_a? Symbol
            association.send @list_record
          elsif @list_record.is_a? Proc
            @list_record.call(association)
          end
        end

        if options.delete(:delay) == true
          # Note that the following assumes that @list_record is a symbol
          instance_eval <<-HEREDOC
            class #{self.name}::Create#{@membership_class}Handler < Fragmentary::Handler
              def call
                association = @args
                #{self.name}.touch_fragments_for_record(association[:#{@list_record.to_s}])
              end
            end

            subscribe_to #{@membership_class} do
              def create_#{@members}_successful(association)
                #{self.name}::Create#{@membership_class}Handler.create(association.to_h)
              end
            end
          HEREDOC
        else
          instance_eval <<-HEREDOC
            subscribe_to #{@membership_class} do
              def create_#{@members}_successful(association)
                touch_fragments_for_record(list_record(association))
              end
            end
          HEREDOC
        end

        instance_eval <<-HEREDOC
          def self.child_search_key
            :record_id
          end
        HEREDOC
      end

    end  # ClassMethods


    # Instance Methods
    # ----------------

    def child_search_key
      self.class.child_search_key
    end

    def set_indexed_children
      return unless child_search_key
      obj = Hash.new {|h, indx| h[indx] = []}
      @indexed_children = children.each_with_object(obj) {|child, collection| collection[child.send(child_search_key)] << child }
    end

    def existing_child(options)
      child(options.merge(:existing => true))
    end

    # Note that this method can be called in two different contexts. One is as part of rendering the parent fragment,
    # which means that the parent was obtained using either Fragment.root or a previous invocation of this method.
    # In this case, the children will have already been loaded and indexed. The second is when the child is being
    # rendered on its own, e.g. inserted by ajax into a parent that is already on the page. In this case the
    # children won't have already been loaded or indexed.
    def child(options)
      if child = options[:child]
        raise ArgumentError, "You passed a child fragment to a parent it's not a child of." unless child.parent_id == self.id
        child
      else
        existing = options.delete(:existing)
        # root_id and parent_id are passed from parent to child. For all except root fragments, root_id is stored explicitly.
        derived_options = {:root_id => root_id || id}
        # record_id is passed from parent to child unless it is required to be provided explicitly.
        derived_options.merge!(:record_id => record_id) unless options[:type].constantize.needs_record_id?
        klass, search_attributes, options = Fragment.base_class.attributes(options.reverse_merge(derived_options))

        # Try to find the child within the children loaded previously
        select_attributes = search_attributes.merge(:type => klass.name)
        if child_search_key and keyed_children = indexed_children.try(:[], select_attributes[child_search_key])
          # If the key was found we don't need to include it in the attributes used for the final selection
          select_attributes.delete(child_search_key)
        end

        # If there isn't a key or there isn't set of previously indexed_children (e.g. the child is being rendered
        # on its own), we just revert to the regular children association.
        fragment = (keyed_children || children).to_a.find{|child| select_attributes.all?{|key, value| child.send(key) == value}}

        # If we didn't find an existing child, create a new record unless only an existing record was requested
        unless fragment or existing
          fragment = klass.new(search_attributes.merge(options))
          children << fragment  # Saves the fragment and sets the parent_id attribute
        end

        # Load the grandchildren, so they'll each be available later. Index them if a search key is available.
        if fragment
          fragment_children = fragment.children
          fragment.set_indexed_children if fragment.child_search_key
        end
        fragment
      end
    end

    # If this fragment's class needs a record_id, it will also have a record_type. If not, we copy the record_id from
    # the parent, if it has one.
    def record_type
      @record_type ||= self.class.needs_record_id? ? self.class.record_type : self.parent.record_type
    end

    # Though each fragment is typically associated with a particular user_type, touching a root fragment will send
    # page requests for the path associated with the fragment to queues for all relevant user_types for this fragment class.
    def request_queues
      self.class.request_queues
    end

    def cache_store
      self.class.cache_store
    end

    def touch(*args, no_request: false)
      request_queues.each{|key, queue| queue << request} if request && !no_request
      super(*args)
    end

    def destroy(options = {})
      options.delete(:delete_matches) ? delete_matched_cache : delete_cache
      super()
    end

    def delete_matched_cache
      cache_store.delete_matched(Regexp.new("#{self.class.model_name.cache_key}/#{id}"))
    end

    def delete_cache
      cache_store.delete(ActiveSupport::Cache.expand_cache_key(self, 'views'))
    end

    def touch_tree(no_request: false)
      children.each{|child| child.touch_tree(:no_request => no_request)}
      # If there are children, we'll have already touched this fragment in the process of touching them.
      touch(:no_request => no_request) unless children.any?
    end

    def touch_or_destroy
      puts "  touch_or_destroy #{self.class.name} #{id}"
      if cache_exist?
        children.each(&:touch_or_destroy)
        touch(:no_request => true) unless children.any?
      else
        destroy  # will also destroy all children because of :dependent => :destroy
      end
    end

    def cache_exist?
      # expand_cache_key calls cache_key and prepends "views/"
      cache_store.exist?(ActiveSupport::Cache.expand_cache_key(self, 'views'))
    end

    # Request-related methods...
    # Note: subclasses that define request_path need to also define self.request_path and should define
    # the instance method in terms of the class method. Likewise, those that define request_parameters
    # also need to defined self.request_parameters and define the instance method in terms of the class method.
    # Subclasses generally don't need to define request_method or request_options, but may need to define
    # self.request_options. The instance method version request_options is defined in terms of the class method
    # below.
    #
    # Also... subclasses that define request_path also need to define self.request, but not the instance method
    # request since that is defined below in terms of its constituent request arguments. The reason is that the
    # class method self.request generally takes a parameter (e.g. a record_id or a key), and this is used in
    # different ways depending on the class, whereas the instance method takes the same form regardless of the class.
    def request_method
      self.class.request_method
    end

    def request_parameters
      self.class.request_parameters # -> nil
    end

    def request_options
      self.class.request_options
    end

    def requestable?
      @requestable ||= respond_to? :request_path
    end

    # Returns a Request object that can be used to send a server request for the fragment content
    def request
      requestable? ? @request ||= Request.new(request_method, request_path, request_parameters, request_options) : nil
    end

    private
    def touch_parent
      parent.try :touch unless previous_changes["memo"]
    end

    module NeedsRecordId
      # needs_record_id means we don't inherit the record_id from the parent
      def needs_record_id?
        true
      end
    end

    module NeedsUserId
      def needs_user_id?
        true
      end
    end

    module NeedsUserType
      def needs_user_type?
        true
      end
    end

    module NeedsKey
      def needs_key?
        true
      end
    end
  end

end
