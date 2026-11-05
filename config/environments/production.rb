# frozen_string_literal: true

require 'active_support/core_ext/integer/time'
require_relative '../../lib/lalabase/instance_settings'

# Host, asset host, TLS and logging come from Lalabase::InstanceSettings. Without
# LALABASE_HOST they are our own servers' values; the Docker image sets it.
instance = Lalabase::InstanceSettings

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # Compress CSS using a preprocessor.
  # config.assets.css_compressor = :sass
  # Disable SCSS compilation since we build CSS externally
  config.assets.css_compressor = nil

  # Do not fall back to assets pipeline if a precompiled asset is missed.
  # Assets should be precompiled in production for performance
  # Set to true only if asset precompilation fails
  config.assets.compile = false
  # Build output, not source: assets:precompile writes it on every deploy (gitignored).
  config.assets.manifest = Rails.root.join('config/manifest.json')

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  config.asset_host = instance.asset_host

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  config.action_cable.url = instance.cable_url
  config.action_cable.allowed_request_origins = instance.cable_origins

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  config.assume_ssl = instance.force_ssl?

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = instance.force_ssl?
  config.ssl_options = {
    hsts: { max_age: 1.year.to_i, include_subdomains: true, preload: true },
    redirect: { exclude: ->(request) { request.path == '/up' } }
  }

  # Use a shared formatter for both stdout and file logging. A container logs on
  # stdout only (RAILS_LOG_TO_STDOUT=1).
  config.log_formatter = ::Logger::Formatter.new

  log_targets = [$stdout]
  if instance.log_to_file?
    log_file = File.open(Rails.root.join('log', "#{Rails.env}.log"), 'a')
    log_file.binmode
    log_file.sync = true
    log_targets << log_file
  end

  multi_io = Class.new do
    def initialize(*targets)
      @targets = targets
    end

    def write(message)
      @targets.each { |target| target.write(message) }
    end

    def close
      @targets.each do |target|
        target.close if target.respond_to?(:close) && target != $stdout
      end
    end

    def flush
      @targets.each { |target| target.flush if target.respond_to?(:flush) }
    end
  end.new(*log_targets)

  combined_logger = ActiveSupport::Logger.new(multi_io)
  combined_logger.formatter = config.log_formatter

  config.logger = ActiveSupport::TaggedLogging.new(combined_logger)

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # Log level configurable via ENV, default is :warn to avoid sensitive data in logs.
  configured_level = ENV.fetch('RAILS_LOG_LEVEL', 'warn')
  config.log_level = configured_level.respond_to?(:to_sym) ? configured_level.to_sym : :warn

  # Suppress Solid Queue SQL chatter unless explicitly required
  config.after_initialize do
    ActiveSupport.on_load(:solid_queue) do
      SolidQueue.logger.level = ::Logger::INFO if SolidQueue.logger
    end
  end

  # A file store, as Rails' default, but in a directory of its own: the default
  # is tmp/cache itself, which bootsnap and the asset caches share, and
  # CacheCleanupJob (FileStore#cleanup) reads every file below the store.
  config.cache_store = :file_store, Rails.root.join('tmp/cache/store')

  # Use a real queuing backend for Active Job. Solid Queue runs on the primary
  # database: the queue connection is pinned to :primary in
  # config/initializers/solid_queue.rb (which Rails loads after this file), and
  # there is no separate :queue database in config/database.yml.
  config.active_job.queue_adapter = :solid_queue
  # config.active_job.queue_name_prefix = "lalabase_production"

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  config.action_mailer.raise_delivery_errors = true

  # Configure default URL options for ActionMailer - Update this with your production domain
  config.action_mailer.default_url_options = { host: instance.mailer_host, protocol: instance.protocol }
  config.action_mailer.asset_host = instance.mailer_asset_host if instance.mailer_asset_host

  # Configure mail delivery method
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true

  # SMTP configuration
  config.action_mailer.smtp_settings = {
    address: ENV.fetch('SMTP_ADDRESS', 'mail.your-server.de'),
    port: ENV.fetch('SMTP_PORT', 587).to_i,
    domain: ENV.fetch('SMTP_DOMAIN', 'lalabase.com'),
    user_name: ENV.fetch('SMTP_USERNAME', 'service@lalabase.com'),
    password: ENV.fetch('SMTP_PASSWORD', ''),
    authentication: :plain,
    enable_starttls_auto: true
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # DNS rebinding and host-header injection protection
  config.hosts = instance.hosts
  # Exclude the health-check endpoint from host checking
  config.host_authorization = { exclude: ->(request) { request.path == '/up' } }
end
