module Fragmentary

  module Fragment

    def self.base_class
      @base_class
    end

    def self.included(base)

      @base_class = base

      base.class_eval do
        include ActionView::Helpers::CacheHelper

        belongs_to :parent, :class_name => name, :optional => true  # because a root fragment doesn't have a parent
        belongs_to :root, :class_name => name, :optional => true    # or a root_id
        has_many :children, :class_name => name, :foreign_key => :parent_id, :dependent => :destroy
        belongs_to :user, :optional => true  # because only fragments that declare 'needs_user_id' require one

        # Don't touch the parent when we create the child - the child was created by
        # rendering the parent, which occured because the parent was touched, thus
        # triggering the current request. Touching it again would result in a
        # redundant duplicate request.
        after_commit :touch_parent, :on => [:update, :destroy]

        attr_accessor :indexed_children

        # Set cache timestamp format to :usec instead of :nsec because the latter is greater precision than Postgres supports,
        # resulting in mismatches between timestamps on a newly created fragment and one retrieved from the database.
        # Probably not needed for Rails 5, which uses :usec by default.
        self.cache_timestamp_format = :usec

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
          fragment = klass.where(search_attributes).includes(:children).first_or_initialize(options);
          fragment.save if fragment.new_record?
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

        if (parent_id = options.delete(:parent_id))
          search_attributes.merge!(:parent_id => parent_id)
        else
          application_root_url_column = Fragmentary.config.application_root_url_column
          if (application_root_url = options.delete(application_root_url_column)) && column_names.include?(application_root_url_column.to_s)
            search_attributes.merge!(application_root_url_column => application_root_url)
          end
        end

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

      # There is one queue per user_type per application instance (the current app and any external instances). The queues
      # for all fragments are held in common by the Fragment base class here in @@request_queues but are also indexed on a
      # subclass basis by an individual subclass's user_types (see the inherited hook below). As well as being accessible
      # here as Fragment.request_queues, the queues are also available without indexation as RequestQueue.all.
      def request_queues
        @@request_queues ||= Hash.new do |hsh, host_url|
          # As well as acting as a hash key to index the set of request queues for a given target application instance
          # (for which its uniqueness is the only requirement), host_url is also passed to the RequestQueue constructor,
          # from which it is used:
          #   (i) by the RequestQueue::Sender to derive the name of the delayed_job queue that will be used to process the
          #       queued requests if the sender is invoked in asynchronous mode - see RequestQueue::Sender#schedulerequests.
          #   (ii) by the Fragmentary::InternalUserSession instantiated by the Sender to configure the session_host.
          hsh[host_url] = Hash.new do |hsh2, user_type|
            hsh2[user_type] = RequestQueue.new(user_type, host_url)
          end
        end
      end

      # Subclass-specific request_queues
      def inherited(subclass)
        subclass.instance_eval do

          def request_queues
            super  # ensure that @@request_queues has been defined
            @request_queues ||= begin
              app_root_url = Fragmentary.application_root_url
              remote_urls = Fragmentary.config.remote_urls
              user_types.each_with_object( Hash.new {|hsh0, url| hsh0[url] = {}} ) do |user_type, hsh|
                # Internal request queues
                hsh[app_root_url][user_type] = @@request_queues[app_root_url][user_type]
                # External request queues
                if remote_urls.any?
                  unless Rails.application.routes.default_url_options[:host]
                    raise "Can't create external request queues without setting Rails.application.routes.default_url_options[:host]"
                  end
                  remote_urls.each {|remote_url| hsh[remote_url][user_type] = @@request_queues[remote_url][user_type]}
                end
              end
            end
          end

        end
        super
      end

      def remove_queued_request(host_url: nil, user:, request_path:)
        u_type = user_type(user)
        if host_url.is_a?(String) and (queue = request_queues[host_url][u_type])
          queue.remove_path(request_path)
        else
          request_queues.each{|key, hsh| hsh[u_type].remove_path(request_path)}
        end
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
      # The user_id is extracted from this option in Fragment.attributes.
      def needs_user_id
        self.extend NeedsUserId
      end

      # If a class declares 'needs_user_type', a user_type value must be provided in the attributes hash in order to either
      # create or retrieve a Fragment of that class. A user_type is needed to distinguish between fragments that are rendered
      # differently depending on the type of user, e.g. to distinguish between content seen by signed in users and those not
      # signed in. When the fragment is instantiated using FragmentsHelper methods 'cache_fragment' or 'CacheBuilder.cache_child',
      # a :user option is added to the options hash automatically from the value of 'current_user'. The user_type is extracted
      # from this option in Fragment.attributes.
      #
      # For each class that declares 'needs_user_type', a set of user_types is defined that determines the set of request_queues
      # that will be used to send requests to the application when a fragment is touched. By default these user_types are defined
      # globally using 'Fragmentary.setup' but they can alternatively be set on a class-specific basis by passing a :session_users
      # option to 'needs_user_type'. See 'Fragmentary.parse_session_users' for details.
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
              set_callback :after_create, :after, ->{subscriber.client.try_request_for_record(record.id)}
            end
          end

          self.extend RecordClassMethods
          define_method(:record){record_type.constantize.find(record_id)}
        end
      end

      module RecordClassMethods
        def remove_fragments_for_record(record_id)
          where(:record_id => record_id).each(&:destroy)
        end

        def try_request_for_record(record_id)
          if requestable?
            queue_request(request(record_id))
          end
        end
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
        fragments_for_record(record_id).includes({:parent => :parent}).each(&:touch)
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
        request_queues.each{|key, hsh| hsh.each{|key2, queue| queue << request}} if request
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
        {}
      end

      def request
        raise NotImplementedError
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
      @no_request = no_request  # stored for use in #touch_parent via the after_commit callback
      request_queues.each{|key, hsh| hsh.each{|key2, queue| queue << request}} if request && !no_request
      super(*args)
    end

    # delete the associated cache content before destroying the fragment
    def destroy(options = {})
      options.delete(:delete_matches) ? delete_matched_cache : delete_cache
      @no_request = options.delete(:no_request)  # stored for use in #touch_parent via the after_commit callback
      super()
    end

    def delete_matched_cache
      cache_store.delete_matched(Regexp.new("#{self.class.model_name.cache_key}/#{id}"))
    end

    def delete_cache
      cache_store.delete(fragment_key)
    end

    # Recursively delete the cache entry for this fragment and all of its children
    # Does NOT destroy the fragment or its children
    def delete_cache_tree
      children.each(&:delete_cache_tree)
      delete_cache if cache_exist?
    end

    # Recursively touch the fragment and all of its children
    def touch_tree(no_request: false)
      children.each{|child| child.touch_tree(:no_request => no_request)}
      # If there are children, we'll have already touched this fragment in the process of touching them.
      touch(:no_request => no_request) unless children.any?
    end

    # Touch this fragment and all descendants that have entries in the cache. Destroy any that
    # don't have cache entries.
    def touch_or_destroy
      if cache_exist?
        children.each(&:touch_or_destroy)
        # if there are children, this will be touched automatically once they are.
        touch(:no_request => true) unless children.any?
      else
        destroy(:no_request => true)  # will also destroy all children because of :dependent => :destroy
      end
    end

    def cache_exist?
      # expand_cache_key calls cache_key and prepends "views/"
      cache_store.exist?(fragment_key)
    end


    # Typically used along with #cache_exist? when testing from the console.
    # Note that both methods will only return correct results for fragments associated with the application_root_url
    # (either root or children) corresponding to the particular console session in use. i.e. you can't see into the
    # production cache from a prerelease console session and vice versa.
    def content
      cache_store.read(fragment_key)
    end

    # This emulates the result of passing the fragment object to AbstractController::Caching::Fragments#combined_fragment_cache_key
    # when the cache helper method invokes controller.read_fragment from the view. The result can be passed to ActiveSupport::Cache methods
    # #read, #write, #fetch, #delete, and #exist?
    def fragment_key
      ['views', self]
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
      parent.try(:touch, {:no_request => @no_request}) unless (previous_changes.none? || previous_changes["memo"])
      @no_request = false
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
