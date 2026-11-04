# frozen_string_literal: true

# app/services/actors/base_actor.rb
#
# Base class for the "Actor" command-object pattern used for non-trivial writes
# (multi-step / own transaction / activity tracking / fanout / background job /
# external API / association sync). An actor encapsulates one write: it runs the
# transaction, maps validation/domain errors to a Result, sets Current.user for
# tracking, and schedules side-effect jobs after commit.
#
# Naming note: "Actor" here means a command object. It is unrelated to
# Activity#actor / Notification#actor, which denote the audit USER who caused a
# change. The collision is intentional but disjoint; do not conflate them.
#
# Two tiers share this class:
# - Tier 1 actors implement #perform (+ #record, + optional #enqueue_jobs) and
#   inherit the #call template below.
# - Tier 2 actors (SaveTicket, MoveTicket) override #call and only reuse the
#   shared helpers (with_error_mapping / with_actor_context / enqueue_after_commit
#   / success / failure / find_or_build), because their flow does not fit the
#   template. They MUST still wrap their body in #with_error_mapping so the
#   failure-mapping policy stays in one place (enforced by the contract guard).

module Actors
  # Raised inside an actor to signal a DOMAIN failure that must become a failed
  # Result (as opposed to an unexpected crash). Carries one or more messages and
  # a machine-readable code, so callers can branch on the failure *kind* (e.g.
  # the API maps it to an HTTP status) instead of sniffing the message strings.
  class ActorError < StandardError
    attr_reader :messages, :code

    def initialize(messages, code: :domain_error)
      @messages = Array(messages)
      @code = code
      super(@messages.join(', '))
    end
  end

  class BaseActor
    # Preferred entry point: Actors::SomeActor.call(foo:, current_user:).
    # PostUpdateService still uses .new(...).call because it needs #record
    # before #call.
    def self.call(**kwargs)
      new(**kwargs).call
    end

    # Tier-1 template. Concrete actors override #perform / #record (and
    # optionally #enqueue_jobs); Tier-2 actors override #call instead, but still
    # wrap their body in #with_error_mapping so the failure policy stays shared.
    def call
      with_error_mapping do
        with_actor_context do
          ActiveRecord::Base.transaction { perform }
          enqueue_jobs
          success(record)
        end
      end
    end

    # Performs the write. Tier-1 actors must implement this.
    def perform
      raise NotImplementedError, "#{self.class} must implement #perform"
    end

    # Primary record the actor operates on, or nil. Drives Result#resource and
    # logging. Every actor must implement this.
    def record
      raise NotImplementedError, "#{self.class} must implement #record"
    end

    # Development-only console logger (unchanged behaviour).
    class ConsoleLog
      def initialize(message)
        return unless Rails.env.development?

        puts '****************************************************'
        puts "Actors::#{self.class.name.split('::').last}"
        puts message
        puts '****************************************************'
      end
    end

    # Standardised return value of every actor.
    class Result
      attr_reader :success, :errors, :resource, :code

      # @param success [Boolean] whether the operation succeeded
      # @param errors [Array] error messages when not successful
      # @param resource [Object] the affected record (e.g. the saved model)
      # @param code [Symbol] machine-readable outcome kind. Defaults to :ok on
      #   success and :error on failure; failure() and with_error_mapping pass a
      #   more specific code (:validation_failed, :stale_object, ...). Callers can
      #   branch on it (e.g. map to an HTTP status) without parsing error strings.
      # @param log_message [String] optional development-only log message
      def initialize(success:, errors: [], resource: nil, code: nil, log_message: nil)
        @success = success
        @errors = errors
        @resource = resource
        @code = code || (success ? :ok : :error)
        ConsoleLog.new(log_message) if log_message.present?
      end

      def success?
        @success
      end
    end

    private

    # Single source of the failure-mapping policy. The Tier-1 #call template and
    # every Tier-2 actor's own #call route their body through this block, so the
    # rescue chain (and the codes it stamps) lives in exactly ONE place and the
    # tiers cannot drift apart. Enforced by actor_contract_guard_spec.
    #
    # Sits OUTSIDE with_actor_context so that, by the time a branch builds a
    # failure, with_actor_context's ensure has already restored the previous
    # Current.user (no actor leaks its user into the failure path).
    def with_error_mapping
      yield
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages, code: :validation_failed)
    rescue ActorError => e
      failure(e.messages, code: e.code)
    rescue ActiveRecord::StaleObjectError
      # Optimistic locking (lock_version): another write landed between read and
      # save. Return a specific, usable message instead of a generic crash/500
      # (mirrors the RecordInvalid path). Only models with a lock_version column
      # raise this; actors of other models are unaffected.
      failure([I18n.t('services.actors.stale_object')], code: :stale_object)
    rescue StandardError => e
      handle_unexpected_error(e, reraise: raise_unexpected?)
    end

    # Hook for Tier-1 actors to schedule background jobs. Implementations must
    # go through #enqueue_after_commit so jobs only fire once data is committed.
    def enqueue_jobs
      nil
    end

    # Registers a block to run after the OUTERMOST real transaction commits
    # (runs immediately when no transaction is open). Correct under nesting:
    # PostUpdateService wraps actor.call in an outer transaction, which makes the
    # actor's own transaction a mere savepoint, so "after the Ruby block" would
    # fire too early. after_all_transactions_commit hangs on the real outer
    # commit instead, and works for the same and a separate queue connection.
    #
    # Accepted residual gap: if the enqueue itself fails AFTER the commit, the
    # job is silently lost. Closing this would require an Outbox pattern, which
    # is intentionally out of scope here.
    def enqueue_after_commit(&block)
      ActiveRecord.after_all_transactions_commit(&block)
    end

    # Sets Current.user for the duration of the block and restores the
    # previous value afterwards, so the actor never leaks a user into a
    # surrounding console/rake/nested-call context. Tracking callbacks fire on
    # commit, which happens before this restore runs.
    #
    # `user` overrides the actor's own current_user for the rare write that
    # must SPLIT attribution within one actor — e.g. SeedOnboarding creates
    # the tutorial content as the new user but performs the assignment as the
    # system account (a foreign actor is what lets the fanout notify the
    # user). ONE implementation on purpose: this is the exact boundary the
    # contract guard protects (no concrete actor assigns Current.user).
    def with_actor_context(user = nil)
      previous = Current.user
      override = user || (respond_to?(:current_user, true) ? current_user : nil)
      Current.user = override if override
      yield
    ensure
      Current.user = previous
    end

    # Last-resort handling for unexpected errors. In dev/test we re-raise (fail
    # loudly to surface bugs); in production we log and return a failure Result
    # instead of bubbling up a 500. Mirrors Trackable#create_activity.
    def handle_unexpected_error(error, reraise:)
      Rails.logger.error("[#{self.class}] #{error.class}: #{error.message}")
      raise error if reraise

      failure([error.message], code: :internal_error)
    end

    def raise_unexpected?
      Rails.application.config.x.actors.reraise_unexpected
    end

    # Finds an existing record by id within an EXPLICITLY tenant-scoped relation,
    # or builds a new one. Never relies on ActsAsTenant.current_tenant or a
    # default_scope: passing the correctly scoped relation is the caller's
    # responsibility, which is what keeps a foreign id from resolving to another
    # tenant's record (it is simply not found, so a fresh record is built).
    #
    # build_scope defaults to find_scope (the common case: find and build in the
    # same relation). Pass a different build_scope when the lookup and the
    # creation are intentionally scoped differently — e.g. SaveTicket finds a
    # ticket org-wide (tickets may move between projects of the org) but builds a
    # new one under the specific project.
    def find_or_build(find_scope, id, build_attrs = {}, build_scope: find_scope)
      (id.present? && find_scope.find_by(id: id)) || build_scope.build(build_attrs)
    end

    def success(resource)
      Result.new(success: true, resource: resource)
    end

    def failure(errors, code: :error)
      Result.new(success: false, resource: safe_record, errors: Array(errors), code: code)
    end

    # #record may itself raise while building the primary record; never let that
    # mask the original failure.
    def safe_record
      record
    rescue StandardError
      nil
    end

    attr_reader :current_user
  end
end
