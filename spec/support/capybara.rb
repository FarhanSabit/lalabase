# frozen_string_literal: true

# spec/support/capybara.rb
require 'capybara/rails'
require 'capybara/rspec'
require 'selenium-webdriver'

# ⚠️ Selenium Manager cannot run on an ARM dev machine.
#
# selenium-webdriver ships exactly ONE Linux binary and it is x86-64
# (bin/linux/selenium-manager); for macOS it ships a universal binary. That is
# the whole reason the same suite runs on the Mac and dies in the Parallels VM.
# On aarch64 the kernel rejects the binary with ENOEXEC, the POSIX fallback
# hands the file to /bin/sh, and the ELF bytes come back as
# `1: Syntax error: "(" unexpected` -- a message that says nothing about
# architecture and sends people looking for a broken shell script.
#
# Naming the driver ourselves skips the manager entirely: DriverFinder reads
# `service.class.driver_path` first and only calls Selenium Manager when that is
# nil (selenium-webdriver driver_finder.rb:47).
#
# This module is the ONE owner of those paths. rails_helper.rb used to repeat
# the decision inside a register_driver block, hardcoded to
# /usr/bin/chromedriver -- which is precisely the spelling several Chromium
# packages do not use, so the fallback into the manager happened anyway.
module LocalChrome
  # ENV first so a machine can override without a patch; then the spellings the
  # common Chromium packages actually install.
  DRIVER_CANDIDATES = [
    ENV.fetch('CHROMEDRIVER_BIN', nil),
    '/usr/bin/chromedriver',
    '/usr/lib/chromium-browser/chromedriver',
    '/usr/lib/chromium/chromedriver',
    '/snap/bin/chromium.chromedriver'
  ].compact.freeze

  # Only consulted when a driver was found: with driver_path set, DriverFinder
  # returns no browser_path, so Chrome is located by chromedriver itself. On a
  # machine where that fails, CHROME_BIN names the browser explicitly.
  BROWSER_CANDIDATES = [
    ENV.fetch('CHROME_BIN', nil),
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/usr/bin/google-chrome'
  ].compact.freeze

  def self.driver_path
    @driver_path ||= DRIVER_CANDIDATES.find { |candidate| executable?(candidate) }
  end

  def self.browser_binary
    @browser_binary ||= BROWSER_CANDIDATES.find { |candidate| executable?(candidate) }
  end

  def self.executable?(candidate)
    !candidate.to_s.empty? && File.executable?(candidate)
  end

  # Every Chrome driver below goes through this, so the ARM workaround cannot be
  # half-applied by adding a fourth driver that forgets it.
  def self.apply_binary(options)
    options.binary = browser_binary if browser_binary
    options
  end

  # A desktop test browser has a mouse, on every machine. Headless Chrome
  # answers the media queries hover and pointer from the input devices it
  # finds: on a Mac a mouse ((hover: hover), (pointer: fine)), on a CI runner
  # none at all ((hover: none), (pointer: none)). The inbox lays its rows out
  # for a touch screen under (hover: none) (the "···" always shown, no
  # checkbox on hover), so the same spec saw the desktop page on a Mac and
  # the touch page in CI, and four examples of spec/system/inbox_spec.rb were
  # red in CI only (2026-11-09 to 2026-11-11). Blink's own numbers: hover 2
  # is "hover", pointer 4 is "fine". Guard: spec/system/test_browser_pointer_spec.rb.
  MOUSE = '--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4'

  def self.with_mouse(options)
    options.add_argument(MOUSE)
    options
  end
end

# On macOS nothing is found here and nothing is set: the universal binary works,
# and Selenium Manager keeps doing its job.
Selenium::WebDriver::Chrome::Service.driver_path = LocalChrome.driver_path if LocalChrome.driver_path

# Configure Capybara to use Chrome in headless mode
Capybara.register_driver :selenium_chrome_headless do |app|
  options = Selenium::WebDriver::Chrome::Options.new

  # Add arguments for headless mode
  options.add_argument('--headless=new') # Use new headless mode
  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.add_argument('--disable-gpu')
  options.add_argument('--window-size=1920,1080')
  LocalChrome.with_mouse(options)

  # Disable images and CSS for faster tests
  options.add_preference('profile.default_content_setting_values.images', 2)
  options.add_preference('profile.managed_default_content_settings.stylesheets', 2)

  Capybara::Selenium::Driver.new(
    app,
    browser: :chrome,
    options: LocalChrome.apply_binary(options)
  )
end

# Configure Capybara for non-headless Chrome (for debugging)
Capybara.register_driver :selenium_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new

  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.add_argument('--window-size=1920,1080')

  Capybara::Selenium::Driver.new(
    app,
    browser: :chrome,
    options: LocalChrome.apply_binary(options)
  )
end

# CSS-/JS-faithful headless driver for visual & JS tests (inbox E2E).
# Unlike :selenium_chrome_headless, CSS + images stay ON, because
# otherwise we cannot correctly check Tailwind visibility (hidden/display:none),
# pane visibility and layout.
Capybara.register_driver :selenium_chrome_headless_full do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument('--headless=new')
  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.add_argument('--disable-gpu')
  options.add_argument('--window-size=1440,900')
  LocalChrome.with_mouse(options)
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: LocalChrome.apply_binary(options))
end

# Optional Playwright driver — only registered when the gem
# capybara-playwright-driver is installed. This keeps the default
# (Selenium) run independent of a Playwright installation.
begin
  require 'capybara/playwright/driver'
  Capybara.register_driver :playwright do |app|
    Capybara::Playwright::Driver.new(app, browser_type: :chromium, headless: true)
  end
rescue LoadError
  # capybara-playwright-driver not installed → :playwright not available.
end

# Set default driver
Capybara.default_driver = :rack_test
Capybara.javascript_driver = :selenium_chrome_headless

# Configure Capybara settings
Capybara.default_max_wait_time = 5
Capybara.server = :puma, { Silent: true }

# Configure for system tests
RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :selenium_chrome_headless
  end

  config.before(:each, type: :system, js: true) do
    driven_by :selenium_chrome_headless
  end

  # Allow using selenium_chrome for debugging specific tests
  config.before(:each, type: :system, debug: true) do
    driven_by :selenium_chrome
  end

  # Inbox E2E specs: driver switchable via ENV.
  #   Default              → :selenium_chrome_headless_full (CSS/JS-faithful)
  #   E2E_DRIVER=playwright → :playwright (needs capybara-playwright-driver)
  # Example: E2E_DRIVER=playwright bundle exec rspec spec/system/inbox_spec.rb
  config.before(:each, :inbox_e2e) do
    if ENV['E2E_DRIVER'].to_s.downcase == 'playwright'
      unless Capybara.drivers.key?(:playwright)
        raise 'E2E_DRIVER=playwright gesetzt, aber capybara-playwright-driver ist ' \
              'nicht installiert. Siehe doc/inbox_qa_matrix.md (Setup-Abschnitt).'
      end
      driven_by :playwright
    else
      driven_by :selenium_chrome_headless_full
    end
  end
end
