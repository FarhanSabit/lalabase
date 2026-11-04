# frozen_string_literal: true

require 'rails_helper'

# What: the hourly sweep of expired cache entries (config/recurring.yml).
# Type: Job spec against a real file store in a temporary directory: the
#       point is which files stay on the disk, and a double has no disk.
# Why:  Production caches in a file store, and a file store deletes nothing on
#       its own. An expired entry (a rate limit counter, which until 2026-10-31
#       named the raw access token in its file name) stays on the disk for good
#       unless this job removes it.
RSpec.describe CacheCleanupJob do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:store) { ActiveSupport::Cache::FileStore.new(File.join(@dir, 'store')) }

  before { allow(Rails).to receive(:cache).and_return(store) }

  it 'deletes expired entries and keeps live ones' do
    store.write('expired', 1, expires_in: 1.minute)
    store.write('live', 2, expires_in: 1.hour)
    store.write('forever', 3)

    travel 2.minutes do
      described_class.perform_now

      expect(store.read('live')).to eq(2)
      expect(store.read('forever')).to eq(3)
    end
    expect(Dir.glob(File.join(@dir, 'store', '**', '*')).select { |f| File.file?(f) }.size).to eq(2)
  end

  # The production store has a directory of its own under tmp/cache
  # (production.rb). This pins what that is for: a file the store did not
  # write survives, so bootsnap and the asset caches next to it would as well.
  it 'leaves a file it did not write alone' do
    foreign = File.join(@dir, 'store', 'foreign.bin')
    FileUtils.mkdir_p(File.dirname(foreign))
    File.binwrite(foreign, "\x04\x08not an entry")

    described_class.perform_now

    expect(File.exist?(foreign)).to be(true)
  end

  # Redis and Memcache expire entries themselves and raise on cleanup.
  it 'does nothing on a store that cannot clean up' do
    allow(Rails).to receive(:cache).and_return(Class.new(ActiveSupport::Cache::Store).new)

    expect { described_class.perform_now }.not_to raise_error
  end
end
