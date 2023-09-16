require 'fragmentary/version'
require 'fragmentary/config'
require 'fragmentary/fragments_helper'
require 'fragmentary/subscriber'
require 'fragmentary/request_queue'
require 'fragmentary/request'
require 'fragmentary/fragment'
require 'fragmentary/handler'
require 'fragmentary/user_session'
require 'fragmentary/session_user'
require 'fragmentary/widget_parser'
require 'fragmentary/widget'
require 'fragmentary/publisher'

module Fragmentary
  def self.config
    @config ||= Fragmentary::Config.instance
    yield @config if block_given?
    @config
  end
  class << self; alias setup config; end

  def self.application
    Rails.application
  end

  def self.application_root_url
    application.routes.url_helpers.root_url
  end
end
