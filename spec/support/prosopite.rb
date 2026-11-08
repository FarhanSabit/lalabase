# frozen_string_literal: true

require 'prosopite'

# Per-record validations that fire independently during factory creation
# are not true N+1 queries — each record save independently validates.
Prosopite.ignore_queries = [
  /SELECT 1 AS one FROM "users".*"email"/, # Devise email uniqueness validation (per-record)
  # ActionText embeds attachments — fires per record save (Note/Post/Ticket before_save → to_plain_text).
  # Not a real N+1: each record's RichText has its own embed lookup as part of save callback.
  /FROM "active_storage_attachments".*"name" = \$3/,
  # `SELECT 1 AS one FROM "X"` — Rails' standard existence-check pattern
  # used by belongs_to validation, acts_as_tenant, and similar per-record checks.
  # Fires once per associated-record save; not a real N+1 since each save validates
  # its own association independently.
  /\ASELECT 1 AS one FROM "\w+"/
]

# Per-record callbacks/validations with app-level call stacks.
# These fire independently for each record and are not true N+1.
Prosopite.allow_stack_paths = [
  'unique_email_among_active_users', # Custom soft-delete-aware email uniqueness
  'auto_subscribe_creator',          # Ticket after_create_commit callback
  'assign_org_recognition_colors',   # Membership after_commit: one memberships.active pluck per record (org recognition color auto-assignment); bounded, not a request N+1
  'assign_next_number',              # Ticket number assignment callback
  'validate_subscribable_exists',    # NotificationSubscription per-record validation
  'validate_user_has_access',        # NotificationSubscription per-record access check
  'system_subscribe',                # NotificationSubscription.system_subscribe called per-user
  'schedule_processing',             # OutboxEvent after_create_commit → Solid Queue job enqueue
  'purge_detached_blobs',            # DestroyPost: one ActiveStorage PurgeJob per detached blob (bounded by attachments per post)
  'with_advisory_lock',              # GroupKeyBuilder: per-recipient advisory lock (intentional)
  'reconcile_existing_post_reads',   # One notification row lock per recipient, required to serialize grouping against acknowledgements; the shared post lock is acquired once outside the recipient loop
  'schedule_delivery',               # FanoutService: per-recipient job enqueue (solid_queue_jobs lookup)
  'batch_schedule_delivery',         # FanoutService: per-recipient delivery batch
  'batch_broadcast',                 # FanoutService: per-recipient Turbo broadcast
  'broadcast_badge_update',          # BroadcastService: per-recipient badge enqueue
  'broadcast_creation',              # BroadcastService: per-notification broadcast enqueue
  'index_outcome_notifier',          # IndexOutcomeNotifier: bounded per-channel (in_app+email) preference resolution for one infrequent index-outcome notification — not an unbounded N+1

  # Pundit loop policy checks — known technical debt:
  # These methods are called per loop element in views/controllers
  # (e.g. user_box per user × area). The correct fix would be request-scoped caching
  # in ProjectAccessService, account_admin_in?, has_permission_in_organisation?.
  # Until then: marked as a known N+1.
  'find_project_permission',          # ProjectAccessService: per-policy-call lookup
  'area_access?',                     # ProjectPolicy: per-loop-element call
  'has_permission_in_organisation?',  # User: per-role-check call
  'account_admin_in?',                # User: per-policy-call admin check
  'role_in_organisation',             # User: per-policy-call role lookup
  'has_any_area_read_access?',        # ProjectPolicy: per-area iteration in show?
  'cached_user_projects',             # ApplicationController: sidebar project filtering
  'time_session_permission_for',      # User: per-user time-permission lookup in user_box loop
  'extract_plain_text_content',       # Note before_save: per-record ActionText to_plain_text → embeds_attachments
  'validate_project_default_uniqueness', # DashboardConfiguration: per-record uniqueness validation
  'validate_custom_attributes', # CustomAttributable: per-record validation loads the project's attribute definitions once per ticket/record save; one query per saved record (not a request N+1) — surfaces only when a spec creates several status-bearing records in one example
  'users_with_any_access', # ProjectAccessService: one users_with_access lookup per ProjectPermission area (7) for one project, bounded by the area list, the inverse of openable_project_ids — not a data N+1
  'knowledge_creator_options', # KnowledgeFilterHelper: a constant ONE users_with_access lookup per knowledge area (2) for the creator filter pool — bounded, not a data N+1
  'backfill_tenant', # Wiki::NoteBackfill: one batched notes scan per organisation (bounded by tenant count) — the repeated identical SQL is the per-tenant loop, not a per-record N+1
  'ensure_due_date', # DueDateBackfillService: one due_date find_by per project in a one-time backfill loop (bounded by project count), not a request N+1
  'aggregate_org_slice', # Dashboard::CrossOrgActionSummary: one bundle of reads per org for the cross-org cockpit (bounded by the user's org count) — the repeated identical SQL is the intentional per-tenant loop, not a per-record N+1; within each org project access is resolved once and lists use includes
  'signal_count_in_organisation', # Notifications::UnreadSignals: one access-filtered count per OTHER organisation that has unread notifications at all (a grouped query decides first), bounded by the user's org count; the per-tenant loop of aggregate_org_slice, for the org switcher dot
  'refresh_later', # Notifications::UnreadSignals.refresh_later: one UnreadSignalsJob per recipient of an in-app notification (fanout of a comment, bulk_transition!), bounded by the recipients of one event. The job carries limits_concurrency, and Solid Queue dispatches such jobs one by one even from perform_all_later (dispatch_all_one_by_one), so each enqueue reads its own semaphore — not a request N+1
  'personal_tasks_for_org', # Dashboard::PersonalTaskRollup: one open-to-dos read per org for the cockpit roll-up (bounded by the user's org count) — the repeated identical SQL is the intentional per-tenant loop, not a per-record N+1
  'role_permission_sync', # RolePermissionSync: one find_or_initialize_by per submitted permission when saving a role's permissions; bounded by Permission::CATEGORIES (32 actions on 2026-11-04), not an unbounded request N+1
  'share_with', # SmartFolder#share_with, called per user by Actors::ShareSmartFolder: one find_or_initialize_by (share existence check) per user when sharing a folder with the picked set — bounded by the handful of users a person selects, each share is an independent write, not a request N+1
  'create_tutorial_tickets', # Actors::SeedOnboarding: one create! per tutorial ticket (bounded by the ~4 content entries, runs once per registration) — per-record callbacks (numbering, activities) are the point, not a request N+1
  'assign_to_user_as_system', # Actors::SeedOnboarding: one TicketAssignmentSync per tutorial ticket (same bounded seed loop as above)
  'record_seat_transition', # SeatEventRecording, Membership after_commit: resolves THAT membership's role (billable flag) and its organisation's account, one lookup each per membership write. Per-record by construction — a callback cannot batch across records — and the same shape as assign_org_recognition_colors above. Surfaces whenever an example creates several memberships in one go
  'classify_account', # Subscriptions::SeatStreamDrift: one stream read per ACCOUNT during the nightly sweep. Per-account by construction -- the reconstruction is account-scoped (a move puts the same pair in two accounts with the same timestamp, s. SeatEvent.for_account), so it cannot be batched into one query. Bounded by the account count, and the two GLOBAL lookups it needs are hoisted out of the loop
  'snapshot_account', # Subscriptions::SeatSnapshotWriter (M1a): one stream read + one snapshot row write per ACCOUNT in the boundary sweep. The read is account-scoped for the same reason as classify_account above; the write is one row per account by definition AND goes through validations on purpose (the status/seat_count/pairs invariant) -- insert_all would batch it and write past them. Bounded by the account count, runs from jobs/rake, never in a request
  'unanswered_accounts', # Subscriptions::SeatSnapshotWriter (M1b): one "which account has no answer for this boundary" query per BOUNDARY, asked TWICE per run: 7 in the monthly fill loop and 7 again in the gap watcher afterwards, so 14 with the default window. Bounded by SeatSnapshotJob::CATCH_UP_MONTHS, not by any record count, and it runs from a job or a rake task, never in a request. Folding all boundaries into a single query was the alternative and was rejected deliberately: the watcher and the writer must never disagree about who is still missing, and that only holds while both ask through THIS one method
  'boundary_snapshot', # Subscriptions::SeatPeak (M2): one snapshot lookup per ACCOUNT. Within ONE evaluation it fires exactly once, and the admin account page (Admin::AccountsController#load_show_data) does exactly one -- so this DOES run in a request, it just does not loop there. The repeated identical SQL is the account loop in `rake seat_peaks:month`, bounded by the account count and run by hand. ⚠️ These two entries are global, so a future SeatPeak in the PAGINATED account list would get no N+1 signal either: that caller has to batch instead (one for_period read plus one windowed event read, both indexed by account), not reuse the per-row entry point
  'events_in_window', # Subscriptions::SeatPeak (M2): the month's events, ONE memoised query per evaluation. Same caller shape, same bound and the same warning as boundary_snapshot above
  'known_seat_pairs_for_account', # Subscriptions::SeatOpeningBackfill: one existing-events read per ACCOUNT in a one-time backfill loop, same account-scoped reason as above. Bounded by the account count, not a request N+1
  'opening_rows_for_organisation', # Subscriptions::SeatOpeningBackfill: one membership read per ORGANISATION of an account. The loop is mandatory, not lazy — Role is acts_as_tenant, so the billable flag only resolves under that organisation's own tenant (same reason SeatCounter iterates). Bounded by the account's organisation count, runs once as a backfill
  'capture_seat_removal_snapshot', # SeatEventRecording, Membership before_destroy: the same two per-record lookups on the removal path, captured before the row disappears. Fires per membership of a cascading organisation delete
  'drop_time_session_permissions', # Membership after_destroy: one delete of the user's time rights per membership leaving an organisation. A user erasure destroys every membership, so this repeats once per organisation of that user (bounded by the user's org count), the same removal-path loop as the entry above
  'membership_role_title', # UserDataExports::Serializers::MembershipsSerializer: one tenant-scoped role read per membership (bounded by the user's org count) — Role is acts_as_tenant, a global preload would raise NoTenantSet; the repeated identical SQL is the intentional per-tenant loop
  'export_org_slice', # UserDataExports::Builder: one bundle of owner-scoped reads per org for the GDPR export (bounded by the user's org count) — the repeated identical SQL is the intentional per-tenant loop, not a per-record N+1; within each org the sources use includes
  'build_grid', # AccessCheck::OrgAccessMatrix: one ProjectMemberAccessResolver per active project (bounded by P). The 3·P query budget is the documented, accepted design — the resolver has no preload seam (see doc/zugriffs_matrix_plan.md §4/C7). Per-USER independence is guarded manually in org_access_matrix_spec.rb; this only silences the intentional per-project loop, not a per-record N+1
  'billable_user_ids', # Subscriptions::SeatCounter: one billable-membership pluck per organisation of an Account (bounded by the account's org count) — deliberate D5/D7 design (with_tenant per org, no rescue), performance tradeoff documented in doc/billing_agentur_konto_plan.md D5
  'violations', # Subscriptions::GuestCeiling: one memberships load + one project-count aggregate per organisation of an Account (bounded by the account's org count) — same deliberate D5-style per-org loop as SeatCounter, read-only detection query (§4.3)
  'violation_for', # Subscriptions::GuestCeiling: single-user variant of the above (used on every membership/project-permission write for the non-blocking hint) — one membership lookup + one project-count query per organisation, same bounded per-org loop, deliberately leaner than #violations (no bulk load of every OTHER user in the account)
  'eligible_owners_by_organisation', # Account: one active-membership load per organisation of an Account for the Admin owner-assignment picker (bounded by the account's org count) — Role is acts_as_tenant, so each org is read under its own tenant (with_tenant), the repeated identical SQL is the intentional per-org loop, not a per-record N+1
  'eligible_owner\?', # Account: single-user variant of the above (Admin assign_owner guard + AccountPolicy#claim?) — one active-membership find_by per organisation until a match, same bounded per-org loop, short-circuited via any?. Escaped \? because Prosopite matches allow_stack_paths as REGEX (frame.match?(str)); a bare `?` would make the `r` optional and over-suppress unrelated frames containing "eligible_owne"
  'each_target_org', # EmbeddingsRakeHelpers: the no-id form of the embeddings ops tasks (check_alignment, gc, backfill_*) sweeps every organisation by design — a fixed handful of aggregates per org, bounded by tenant count. The repeated identical SQL IS that loop, not a per-record N+1, and these run in a rake process, never in a request
  'roll_up', # AiUsageRollupJob (T17): one usage aggregate per CALENDAR MONTH in the monthly catch-up, bounded by CATCH_UP_MONTHS (6). Re-checking the recent past is what makes a missed run self-healing; collapsing it into one query would need a second month-boundary definition (see flush_period below)
  'flush_period', # Subscriptions::AiUsageAggregator (T17): one usage aggregate per CALENDAR MONTH when an organisation is deleted, bounded by the months that organisation actually has consumption in. Same single-boundary reasoning as missing_periods below; the organisation itself is passed down, so no per-month record lookup remains. Runs in a before_destroy, never in a request
  'missing_periods', # Subscriptions::AiUsageAggregator (T17): one usage aggregate + one rollup pluck per CALENDAR MONTH in the gap watcher, bounded by the six-month window its callers pass in. The loop is the price of having exactly ONE definition of a month boundary (month_range, matching QuotaLedger#used) — folding it into a single date_trunc query would introduce a second, subtly different boundary in the very code whose job it is to find gaps left by the first. Runs in the monthly job and in rake, never in a request
  'from_attachable_sgid', # ActionText: one Blob.find per <action-text-attachment sgid> when a rich text with images is saved or rendered (GlobalID::Locator.locate_signed, ActionText's own embeds sync in before_save does the same). Bounded by the images in ONE text, inherent to ActionText, not a per-record N+1 of our code; the cost per screenshot is the Paket-2 measurement of doc/inline_bilder_spike_plan.md (E2). RichTextEmbedGuard's own queries stay under watch
  'db/seeds/demo', # db/seeds/demo.rb: five demo tickets saved one by one through Actors::SaveTicket, each with its own assignment sync, as a real user would create them. Bounded by DemoSeed::TICKETS, run from db:seed in development only, never in a request. Surfaces only in spec/db/seeds_spec.rb
  'db/seeds/prompt_personas', # db/seeds/prompt_personas.rb: one find_or_initialize_by per seeded persona (bounded by the entries in GLOBAL_PROMPT_PERSONAS, four today), run from db:seed or a rails runner, never in a request. Surfaces only in spec/db/seeds/prompt_personas_spec.rb, which loads the file on purpose
  'projects_in_organisation', # PersonalAccessTokens::ReachListing#projects: one bundle of reads per ORGANISATION (the policy-scoped projects and, for MCP, the area reads of ProjectAccessService.openable_project_ids) the token reaches (PersonalAccessToken#organisation_scopes), bounded by that handful, the per-tenant loop of aggregate_org_slice. Hidden until 2026-10-02 by Pundit memoising policy_scope(Project) per class, which also answered every organisation with the first one's projects
  'inbox_query_readable_rows', # Notifications::InboxQuery: the AREA resolution behind Notification.readable (one per area the mapping names, plus any area) for ONE organisation of a token's reach. Same bounded per-organisation loop as inbox_query_current_access below: for a role with rights in all projects it is one exclusion read (ProjectAccessService.find_excluded_project_ids_for_area) per area and organisation, bounded by the organisations the TOKEN names. Pinned: area_rights_spec.rb, the token inbox over organisations
  'open_hours_in_organisation', # TimeSessions::OpenHours (GET /api/v1/time_sessions/open): one ViewingScope resolution per ORGANISATION in a token's reach (active membership, admin check, ONE read of the time permission rows), to narrow that organisation's own bookings the way TimeSessionPolicy::Scope does. ViewingScope answers per organisation by construction, so the loop is mandatory; it is bounded by the organisations the TOKEN names, not by any record count. A frame of its own for the same reason as inbox_query_current_access below
  'readable_open_hour_tickets', # TimeSessions::OpenHours: one TicketPolicy::Scope resolution plus one pluck per ORGANISATION that has a ticket on the current page (at most the organisations of the token, and at most per_page rows), the tickets the person may read. The policy scope takes one organisation as its tenant, so the loop is mandatory; a check per ROW would be the real N+1 (time_sessions_open_access_spec.rb pins it)
  'inbox_query_current_access', # Notifications::InboxQuery: one project-access RESOLUTION per ORGANISATION in a token's reach, for the API and MCP notification list. Not one query — a resolution is a membership check, a role read and the service's own reads, so read this as a bundle per organisation, the same way aggregate_org_slice and export_org_slice above are bundles. AccessCheck::ProjectAccessService answers per organisation by construction, so the loop is mandatory; it is bounded by the organisations the TOKEN names (a handful), not by any record count. Deliberately a frame of its OWN rather than an entry on ProjectAccessService: silencing the service itself would blind every other caller in the app to a real N+1. What this does NOT cover, because Prosopite groups by query shape and each of them names a different column: the eight per-AREA project_permissions reads inside find_projects_with_local_permissions. Those are one OR-query's worth of work spread over eight, they cost every policy scope in the app, and they belong to ProjectAccessService, not here. The organisation lookup that used to repeat here is batched (InboxQuery#reach_organisations)
  'same_organisation_references', # TermCorrection / TermApplication validation: one unscoped owner read per reference (meeting, project, term) of ONE saved row, the check that a reference belongs to the row's organisation. Per-record by construction, bounded by the three references; surfaces when a spec builds several rows in one example. The bulk writer TermApplication.record! does not go through it (two statements for the whole list)
  'erase_person_links!', # PersonalDataErasure: one destroy per people directory row linked to the erased account, so each row leaves its anonymous person.deleted activity (PersonTrackable). At most one row per organisation the account was in (unique index), run once per erasure, never in a request
  'collect_space' # Embeddings::OrphanGc sweep 3 (PR 6b): one batched delete pass per COLLECTED SPACE. Bounded by the org's retention limit (1..5, so at most four spaces past it) and run by the nightly GC, never in a request. Folding the spaces into ONE delete would save a handful of queries and cost the per-space count that the GDPR attribution log and the "no silent caps" rule both need — the repeated identical SQL IS the per-space loop, not a per-record N+1. As a REGEX this prefix also matches collect_spaces_for frames — intentional: the per-ORG decision queries (ordered_spaces, per-space counts) are the same deliberate bounded loop, and the two-org sweep-3 specs rely on that coverage
]

RSpec.configure do |config|
  config.before(:each) do
    Prosopite.scan
  end

  config.after(:each) do
    Prosopite.finish
  end
end
