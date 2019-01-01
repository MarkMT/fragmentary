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
