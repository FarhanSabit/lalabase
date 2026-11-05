# frozen_string_literal: true

# What: the production settings that name an instance's host
#   (Lalabase::InstanceSettings) and the production.rb that reads them.
# Why: the Docker image needs its own host, no asset host, optional TLS and
#   stdout logging. Our servers must not notice: they run without any of the new
#   variables and no deploy may depend on a new line in the shared .env
#   (decision 2026-10-01: Docker is for self-hosters, production stays as it is).
#   Every value here is invisible in the test environment, which allows all
#   hosts and never forces TLS, so the module is tested on its own and
#   production.rb is evaluated against a recorder.
# Contract:
#   * without LALABASE_HOST, production.rb yields the literal values it carried
#     before (pinned below as literals, not as the module's constants)
#   * with LALABASE_HOST, that host is the only one allowed, there is no asset
#     host, Action Cable follows the page's host, mails link and load images there
#   * ASSET_HOST, LALABASE_FORCE_SSL and RAILS_LOG_TO_STDOUT act on a
#     self-hosted instance only. Two of them are common names from Rails
#     templates; a stray line in our servers' shared .env must stay as inert
#     as it was before (review of #952, 2026-10-01)
#   * TLS stays on unless LALABASE_FORCE_SSL is 0, false or no; a blank value
#     keeps it on
#   * RAILS_LOG_TO_STDOUT=1/true/yes drops the log file, 0/false keeps it
#   * /up passes the host check and the https redirect: the container's health
#     check calls it as localhost, whatever LALABASE_HOST says
require 'rails_helper'

RSpec.describe Lalabase::InstanceSettings do
  # The real host check, the way Rails builds it from config.hosts.
  def host_allowed?(hosts, host)
    app = ActionDispatch::HostAuthorization.new(->(_env) { [200, {}, ['ok']] }, hosts)
    app.call(Rack::MockRequest.env_for('/', 'HTTP_HOST' => host)).first == 200
  end

  def origin_allowed?(origins, origin)
    origins.any? { |allowed| allowed === origin } # rubocop:disable Style/CaseEquality
  end

  context 'on our own servers (no LALABASE_HOST)' do
    let(:env) { {} }

    it 'is not self-hosted' do
      expect(described_class.self_hosted?(env)).to be(false)
    end

    it 'allows lalabase.com and its subdomains only' do
      hosts = described_class.hosts(env)
      expect(%w[lalabase.com www.lalabase.com stage.lalabase.com]).to all(satisfy { |h| host_allowed?(hosts, h) })
      expect(host_allowed?(hosts, 'evil.example')).to be(false)
    end

    it 'keeps the asset host, the cable address and TLS' do
      expect(described_class.asset_host(env)).to eq('https://lalabase.com')
      expect(described_class.cable_url(env)).to eq('wss://lalabase.com/cable')
      expect(described_class.cable_origins(env)).to eq(['https://lalabase.com', 'https://www.lalabase.com'])
      expect(described_class.force_ssl?(env)).to be(true)
    end

    it 'links mails to lalabase.com unless MAILER_DEFAULT_URL_HOST says otherwise' do
      expect(described_class.mailer_host(env)).to eq('lalabase.com')
      expect(described_class.mailer_host('MAILER_DEFAULT_URL_HOST' => 'mail.example')).to eq('mail.example')
      expect(described_class.mailer_asset_host(env)).to be_nil
    end

    # Before, an empty value gave links to https:///... Now it falls back.
    it 'falls back to lalabase.com for a blank MAILER_DEFAULT_URL_HOST' do
      expect(described_class.mailer_host('MAILER_DEFAULT_URL_HOST' => ' ')).to eq('lalabase.com')
    end

    # The old production.rb read none of these. ASSET_HOST and
    # RAILS_LOG_TO_STDOUT are common lines in Rails and Heroku templates.
    context 'with lines in the shared .env that used to be inert' do
      let(:stray) { { 'ASSET_HOST' => '', 'RAILS_LOG_TO_STDOUT' => 'true', 'LALABASE_FORCE_SSL' => 'false' } }

      it 'keeps the asset host, also for mails' do
        expect(described_class.asset_host(stray)).to eq('https://lalabase.com')
        expect(described_class.asset_host('ASSET_HOST' => 'https://cdn.example')).to eq('https://lalabase.com')
        expect(described_class.mailer_asset_host(stray)).to be_nil
      end

      it 'keeps the log file and TLS' do
        expect(described_class.log_to_file?(stray)).to be(true)
        expect(described_class.force_ssl?(stray)).to be(true)
      end
    end

    it 'logs to a file as well' do
      expect(described_class.log_to_file?(env)).to be(true)
    end

    # A blanked line in a .env must not turn our servers into a self-hosted
    # instance with an empty host list.
    it 'treats a blank LALABASE_HOST as unset' do
      expect(described_class.self_hosted?('LALABASE_HOST' => '  ')).to be(false)
      expect(described_class.hosts('LALABASE_HOST' => '')).to eq(described_class.hosts(env))
    end
  end

  context 'on a self-hosted instance' do
    let(:env) { { 'LALABASE_HOST' => 'tickets.example.org' } }

    it 'allows its own host and refuses ours' do
      hosts = described_class.hosts(env)
      expect(host_allowed?(hosts, 'tickets.example.org')).to be(true)
      expect(host_allowed?(hosts, 'lalabase.com')).to be(false)
      expect(host_allowed?(hosts, 'evil.example')).to be(false)
    end

    it 'serves its assets itself and lets Action Cable follow the page' do
      expect(described_class.asset_host(env)).to be_nil
      expect(described_class.cable_url(env)).to be_nil
    end

    it 'accepts cable connections from its own pages only' do
      origins = described_class.cable_origins(env)
      expect(origin_allowed?(origins, 'https://tickets.example.org')).to be(true)
      expect(origin_allowed?(origins, 'https://lalabase.com')).to be(false)
      expect(origin_allowed?(origins, 'https://tickets.example.org.evil.example')).to be(false)
      expect(origin_allowed?(origins, 'https://evil.tickets.example.org')).to be(false)
      # The dots are literal: an unescaped pattern would admit any character there.
      expect(origin_allowed?(origins, 'https://ticketsXexample.org')).to be(false)
    end

    it 'links mails and their images to itself' do
      expect(described_class.mailer_host(env)).to eq('tickets.example.org')
      expect(described_class.mailer_asset_host(env)).to eq('https://tickets.example.org')
    end

    it 'takes an explicit ASSET_HOST, and an empty one as none' do
      expect(described_class.asset_host(env.merge('ASSET_HOST' => 'https://cdn.example.org')))
        .to eq('https://cdn.example.org')
      expect(described_class.asset_host(env.merge('ASSET_HOST' => ''))).to be_nil
    end
  end

  # Trying the image on a laptop: no proxy, no certificate, a port in the host.
  context 'on localhost without TLS' do
    let(:env) { { 'LALABASE_HOST' => 'localhost:3000', 'LALABASE_FORCE_SSL' => 'false' } }

    it 'answers on the port and accepts its plain-http pages for Action Cable' do
      expect(host_allowed?(described_class.hosts(env), 'localhost:3000')).to be(true)
      expect(origin_allowed?(described_class.cable_origins(env), 'http://localhost:3000')).to be(true)
    end

    it 'links mails over http, port included' do
      expect(described_class.protocol(env)).to eq('http')
      expect(described_class.mailer_asset_host(env)).to eq('http://localhost:3000')
    end
  end

  describe '.force_ssl? on a self-hosted instance' do
    let(:host) { { 'LALABASE_HOST' => 'tickets.example.org' } }

    %w[0 false FALSE no].each do |value|
      it "is off for #{value.inspect}" do
        expect(described_class.force_ssl?(host.merge('LALABASE_FORCE_SSL' => value))).to be(false)
      end
    end

    # Ruby treats every set string as true; the reverse mistake here would be
    # a blank line silently dropping TLS.
    ['', ' ', '1', 'true', 'off'].each do |value|
      it "stays on for #{value.inspect}" do
        expect(described_class.force_ssl?(host.merge('LALABASE_FORCE_SSL' => value))).to be(true)
      end
    end
  end

  describe '.log_to_file? on a self-hosted instance' do
    let(:host) { { 'LALABASE_HOST' => 'tickets.example.org' } }

    %w[1 true yes].each do |value|
      it "drops the file for RAILS_LOG_TO_STDOUT=#{value}" do
        expect(described_class.log_to_file?(host.merge('RAILS_LOG_TO_STDOUT' => value))).to be(false)
      end
    end

    ['', '0', 'false'].each do |value|
      it "keeps the file for #{value.inspect}" do
        expect(described_class.log_to_file?(host.merge('RAILS_LOG_TO_STDOUT' => value))).to be(true)
      end
    end
  end
end

# Records what production.rb assigns instead of configuring the running app.
# Unknown readers return a nested recorder, so `config.action_mailer.x = y`
# works; calls with a block (after_initialize) are swallowed. A BasicObject:
# in the test environment every Object answers `default_url_options=` (the
# routing helpers are mixed into Object), which would swallow that assignment.
class ProductionConfigRecorder < BasicObject
  def initialize
    @values = {}
  end

  delegate :[], :key?, to: :@values

  def method_missing(name, *args, &block)
    key = name.to_s
    if key.end_with?('=')
      @values[key.chomp('=').to_sym] = args.first
    elsif args.empty? && block.nil?
      @values[name] ||= ::ProductionConfigRecorder.new
    end
  end

  def respond_to_missing?(_name, _include_private = false)
    true
  end
end

RSpec.describe 'config/environments/production.rb' do
  let(:new_vars) { %w[LALABASE_HOST ASSET_HOST LALABASE_FORCE_SSL RAILS_LOG_TO_STDOUT MAILER_DEFAULT_URL_HOST] }

  def evaluate(vars = {})
    recorder = ProductionConfigRecorder.new
    previous = new_vars.index_with { |name| ENV.fetch(name, nil) }
    new_vars.each { |name| ENV[name] = vars[name] }
    allow(Rails.application).to receive(:configure) do |&block|
      Struct.new(:config).new(recorder).instance_eval(&block)
    end
    load Rails.root.join('config/environments/production.rb').to_s
    recorder
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end

  # The values production.rb carried as literals before 2026-10-01, written out
  # again here. A change to any of them would reach our servers on the next
  # deploy without anyone setting a variable.
  context 'without the new variables (our servers)' do
    subject(:config) { evaluate }

    it 'keeps lalabase.com as the only host family' do
      expect(config[:hosts]).to eq(['lalabase.com', 'www.lalabase.com', /.*\.lalabase\.com/])
    end

    it 'keeps the asset host and the cable address' do
      expect(config[:asset_host]).to eq('https://lalabase.com')
      expect(config[:action_cable][:url]).to eq('wss://lalabase.com/cable')
      expect(config[:action_cable][:allowed_request_origins])
        .to eq(['https://lalabase.com', 'https://www.lalabase.com'])
    end

    it 'keeps TLS' do
      expect([config[:force_ssl], config[:assume_ssl]]).to eq([true, true])
    end

    it 'keeps the mail links and leaves the mail asset host to Rails' do
      expect(config[:action_mailer][:default_url_options]).to eq(host: 'lalabase.com', protocol: 'https')
      expect(config[:action_mailer].key?(:asset_host)).to be(false)
    end
  end

  # The cache gets a directory of its own under tmp/cache. Rails' default is
  # tmp/cache itself, where bootsnap and the asset caches live too, and
  # CacheCleanupJob (FileStore#cleanup) reads every file below the store's
  # directory. In every environment of production.rb, the image included.
  describe 'the cache store' do
    it 'is a file store in tmp/cache/store, with or without LALABASE_HOST' do
      [evaluate, evaluate('LALABASE_HOST' => 'tickets.example.org')].each do |config|
        expect(config[:cache_store]).to eq([:file_store, Rails.root.join('tmp/cache/store')])
      end
    end
  end

  # Lines a shared .env may carry from an old template. production.rb used to
  # ignore them, and it still must.
  context 'on our servers with ASSET_HOST, RAILS_LOG_TO_STDOUT and LALABASE_FORCE_SSL lines' do
    subject(:config) do
      evaluate('ASSET_HOST' => '', 'RAILS_LOG_TO_STDOUT' => 'true', 'LALABASE_FORCE_SSL' => 'false')
    end

    it 'yields the same values as without them' do
      expect(config[:asset_host]).to eq('https://lalabase.com')
      expect([config[:force_ssl], config[:assume_ssl]]).to eq([true, true])
      expect(config[:action_mailer].key?(:asset_host)).to be(false)
    end
  end

  # The container's health check asks for /up on localhost, whatever
  # LALABASE_HOST is, and over plain http. Without these two exemptions web
  # never turns healthy and compose starts neither the worker nor Caddy.
  describe 'the /up exemptions' do
    subject(:config) { evaluate('LALABASE_HOST' => 'tickets.example.org') }

    def request_for(path)
      Rack::Request.new(Rack::MockRequest.env_for(path))
    end

    it 'lets /up past the host check, and nothing else' do
      exclude = config[:host_authorization][:exclude]
      expect(exclude.call(request_for('/up'))).to be(true)
      expect(exclude.call(request_for('/'))).to be(false)
      expect(exclude.call(request_for('/users/sign_in'))).to be(false)
    end

    it 'lets /up past the https redirect, and nothing else' do
      exclude = config[:ssl_options][:redirect][:exclude]
      expect(exclude.call(request_for('/up'))).to be(true)
      expect(exclude.call(request_for('/'))).to be(false)
    end
  end

  context 'with LALABASE_HOST (the Docker image)' do
    subject(:config) do
      evaluate('LALABASE_HOST' => 'tickets.example.org', 'RAILS_LOG_TO_STDOUT' => '1')
    end

    it 'names the instance host instead of ours' do
      expect(config[:hosts]).to eq(['tickets.example.org'])
      expect(config[:asset_host]).to be_nil
      expect(config[:action_cable][:url]).to be_nil
      expect(config[:action_mailer][:default_url_options]).to eq(host: 'tickets.example.org', protocol: 'https')
      expect(config[:action_mailer][:asset_host]).to eq('https://tickets.example.org')
    end
  end

  context 'with LALABASE_FORCE_SSL=false (a trial on localhost)' do
    subject(:config) do
      evaluate('LALABASE_HOST' => 'localhost:3000', 'LALABASE_FORCE_SSL' => 'false')
    end

    it 'neither forces nor assumes TLS, and links mails over http' do
      expect([config[:force_ssl], config[:assume_ssl]]).to eq([false, false])
      expect(config[:action_mailer][:default_url_options]).to eq(host: 'localhost:3000', protocol: 'http')
    end
  end
end
