# frozen_string_literal: true

# Deletes expired cache entries, hourly (config/recurring.yml).
#
# Production caches in a file store (production.rb, tmp/cache/store), and a
# file store never deletes an expired entry on its own: it only skips it on
# read. Rack::Attack writes a counter per client and minute there, so without
# this sweep the directory grows by every counter ever written, and whatever a
# key named stays on the disk. Emptying tmp/ instead is no substitute: it also
# deletes the server's socket under tmp/sockets. Entries without an expiry
# stay, as in any store.
#
# Stores that expire entries themselves (Redis on staging, Memcache, Solid
# Cache) raise NotImplementedError from #cleanup; there is nothing to do.
class CacheCleanupJob < ApplicationJob
  queue_as :default

  def perform
    Rails.cache.cleanup
  rescue NotImplementedError
    nil
  end
end
