# frozen_string_literal: true

# spec/rails_helper.rb
require 'spec_helper'

ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
abort('The Rails environment is running in production mode!') if Rails.env.production?
require 'rspec/rails'

# Make sure route helpers are available everywhere
RSpec.configure do |config|
  config.include Rails.application.routes.url_helpers
end
Rails.application.routes.default_url_options[:host] = 'www.example.com'

# Add PagyTestMocks before it is used
module PagyTestMocks
  def mock_pagy
    double('Pagy',
           page: 1,
           pages: 2,
           count: 20,
           from: 1,
           to: 10,
           prev: nil,
           next: 2,
           series: [1, 2])
  end
end

# Add additional requires below this line. Rails is not loaded until this point!
require 'devise'
require 'pundit/matchers'
require 'capybara/rails'
require 'capybara/rspec'
require 'selenium-webdriver'
require 'view_component/test_helpers'
require 'view_component/system_test_helpers'

# Include URL helpers in RSpec tests
# This makes route helpers like root_path, new_user_session_path available directly
include Rails.application.routes.url_helpers

# Set default URL options for URL helpers in tests
# This is required for proper route generation in specs
Rails.application.routes.default_url_options[:host] = 'www.example.com'

# Loading files in spec/support and subdirectories
Dir[Rails.root.join('spec/support/**/*.rb')].sort.each { |f| require f }

# Checking migrations
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  puts e.to_s.strip
  exit 1
end

# Configuration for testing upload files (only for matching test types)
RSpec.configure do |config|
  config.include ActionDispatch::TestProcess, type: :request
  config.include ActionDispatch::TestProcess, type: :controller
  config.include ActionDispatch::TestProcess, type: :system
end

RSpec.configure do |config|
  config.fixture_paths = ["#{Rails.root.join('spec/fixtures')}"]
  config.use_transactional_fixtures = true

  # Live-LLM measurement harnesses (e.g. participant_detection_live_spec) hit a
  # real provider API and NEVER run in CI/default rspec — only with an explicit
  # LLM_LIVE=1 opt-in (they additionally skip without an API key).
  config.filter_run_excluding llm_live: true unless ENV['LLM_LIVE']
  # The product screenshots for the project website (spec/marketing/screenshots_spec.rb): a tool, not a test.
  config.filter_run_excluding marketing_screenshots: true unless ENV['MARKETING_SCREENSHOTS']

  # Measurements that need the REAL handbook, not the two-page example fixture
  # this suite otherwise reads. The handbook lives in
  # gboyke/lalabase-documentation since the split, so these run against a
  # catalogue generated there:
  #
  #   # in the documentation repository
  #   DOCS_CATALOGUE_PATH=/tmp/catalogue bin/rails catalogue:write
  #   # here
  #   REAL_CATALOGUE=1 DOCS_CATALOGUE_PATH=/tmp/catalogue bundle exec rspec <spec>
  #
  # Only the tagged examples see that catalogue (spec/support/docs_catalogue.rb
  # hands it to them by tag), so the variable can be set for a whole suite run
  # without breaking the examples that name a page of the fixture.
  #
  # They are measurements, not guards: they say how well something works, not
  # that it still works. The fixture cannot carry the handbook, because this
  # repository is going open source (doc/docs_delivery_plan.md, goal 1).
  config.filter_run_excluding real_catalogue: true unless ENV['REAL_CATALOGUE']

  # Enable automatic derivation of the test type from the file name
  config.infer_spec_type_from_file_location!

  # Add the Pagy test mocks
  config.include PagyTestMocks

  # Filter Rails backtrace
  config.filter_rails_from_backtrace!

  # Devise test helpers
  config.include Devise::Test::ControllerHelpers, type: :controller
  config.include Devise::Test::IntegrationHelpers, type: :request
  config.include Devise::Test::IntegrationHelpers, type: :system

  # ViewComponent test helpers
  config.include ViewComponent::TestHelpers, type: :component
  config.include ViewComponent::SystemTestHelpers, type: :component
  config.include Capybara::RSpecMatchers, type: :component

  # Warden test helpers
  config.include Warden::Test::Helpers

  config.before(:suite) do
    Warden.test_mode!
  end

  config.after(:each) do
    Warden.test_reset!
    Current.reset
  end

  # Make FactoryBot methods available
  config.include FactoryBot::Syntax::Methods

  # Include ActiveJob test helpers
  config.include ActiveJob::TestHelper

  # Clear jobs before each test
  config.before(:each) do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  # Use 'expect' syntax
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Allow the use of doubles for ActiveRecord models
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # Filter other gems if desired

  config.include Turbo::Streams::ActionHelper, type: :controller
  config.include Turbo::Streams::ActionHelper, type: :request
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

# Capybara configuration
Capybara.default_driver = :rack_test
Capybara.javascript_driver = :selenium_chrome_headless

# ⚠️ This re-registers :selenium_chrome_headless, which spec/support/capybara.rb
# already defines (support files load in line 56, so THIS one wins). The two
# differ in more than whitespace -- the other switches images and stylesheets
# off -- so which of them a system test actually gets is decided by load order
# alone. Left as it is here on purpose; untangling it changes what those tests
# see and belongs in its own change.
#
# What did move out is the chromedriver path: it was hardcoded to
# /usr/bin/chromedriver in this block, which several Chromium packages do not
# use, and it now lives once in LocalChrome (spec/support/capybara.rb) together
# with the reason it exists at all.
Capybara.register_driver :selenium_chrome_headless do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument('--headless')
  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.add_argument('--disable-gpu')
  options.add_argument('--window-size=1920,1080')
  LocalChrome.with_mouse(options)

  Capybara::Selenium::Driver.new(app,
                                 browser: :chrome,
                                 options: LocalChrome.apply_binary(options))
end

# Configure Capybara
Capybara.server = :puma, { Silent: true }
Capybara.default_max_wait_time = 5
Capybara.enable_aria_label = true
