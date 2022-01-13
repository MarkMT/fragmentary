### 0.3.0
- Updates gem to support Rails 5.x (Rails 4.x and earlier are no longer supported due to Rails API changes).
- Adds support for multiple application instances, allowing pre-release application code to be staged for testing.
- Fixes a bug in Fragment.set_record_type affecting some application data handlers for fragment classes that are subclassed from another.

### 0.2.2
- Removes validation of the fragment's root_id (only relevant to child fragments); ignore v0.2.1

### 0.2.1
- Fixes a syntax bug in validating a fragment's root_id
- Adds README documentation on the use of methods for explicitly retreving user-dependent fragments.
- Adds README documentation on the needs_user_id declaration
- Deprecates the :template parameter in FragmentsHelper#fragment_builder
- Adds minor performance enhancements

### 0.2.0
- Makes the following configurable:
  - current_user_method - called on current template to obtain the current authenticated user.
  - user_type_mapping - returns user_type for current user, configurable globally and per fragment class
  - session_users for background requests, configurable globally and per fragment class
  - sign-in/sign-out paths for background requests
- For root fragments with `needs_record_id`, a declared `record_type` and a defined class method `request_path`, automatically generates internal requests to the specified path when application records of the associated type are created (extracts
behavior that was previously handled in the application).
- Makes Fragment.requestable? reflect only the existence of a class :request_path
- Modifies interface for Fragment.queue_request and Fragment.remove_queued_request
- Adds event handlers to subscribers via an anonymous module so that subclasses can access them via `super`
