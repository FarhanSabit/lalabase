# frozen_string_literal: true

# The Notification model is the heart of the notification system.
#
# PURPOSE:
# A notification represents a message to a user about something
# important that happened (new comment, ticket assignment, etc.).
#
# WHY BUILT THIS WAY:
# - Can refer to anything (tickets, projects, documents) via polymorphic association
# - Automatically groups similar messages (5 comments = 1 notification)
# - Prevents duplicates via a unique fingerprint
# - Supports different channels (in-app, e-mail, webhook)
# - Tracks the complete lifecycle (queued → sent → delivered → read)
#
# EXAMPLE:
# "Tim assigned you ticket #123" → one notification
# "3 new comments on ticket #123" → one grouped notification

# == Schema Information
#
# Table name: notifications
#
#  id                 :uuid             not null, primary key
#  archived_at        :datetime
#  channel            :enum             default("in_app"), not null
#  dedupe_fingerprint :string           not null
#  delivered_at       :datetime
#  event_type         :enum             not null
#  first_event_at     :datetime         not null
#  group_count        :integer          default(1), not null
#  group_key          :string           not null
#  last_event_at      :datetime         not null
#  next_allowed_at    :datetime
#  notifiable_type    :string           not null
#  payload            :jsonb            not null
#  priority           :enum             default("normal"), not null
#  read_at            :datetime
#  score              :integer          default(0), not null
#  sent_at            :datetime
#  state              :enum             default("queued"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  actor_id           :uuid
#  notifiable_id      :uuid             not null
#  organisation_id    :uuid             not null
#  project_id         :uuid
#  recipient_id       :uuid             not null
#
# Indexes
#
#  idx_notifications_notifiable                    (notifiable_type,notifiable_id)
#  idx_notifications_recipient_state               (recipient_id,state,created_at)
#  idx_notifications_tenant_recipient              (organisation_id,recipient_id,state,created_at)
#  idx_unique_dedupe                               (recipient_id,channel,dedupe_fingerprint) UNIQUE
#  index_notifications_on_actor_id                 (actor_id)
#  index_notifications_on_event_type               (event_type)
#  index_notifications_on_group_key                (group_key)
#  index_notifications_on_notifiable               (notifiable_type,notifiable_id)
#  index_notifications_on_organisation_id          (organisation_id)
#  index_notifications_on_payload                  (payload) USING gin
#  index_notifications_on_project_and_created_at   (project_id,created_at)
#  index_notifications_on_project_id               (project_id)
#  index_notifications_on_recipient_id             (recipient_id)
#  index_notifications_on_recipient_project_state  (recipient_id,project_id,state)
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (recipient_id => users.id)
#
class Notification < ApplicationRecord
  # Include the module with the constants
  include Notifications::Constants

  # Multi-tenancy
  acts_as_tenant(:organisation)

  # Associations
  belongs_to :recipient, class_name: 'User'
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :notifiable, polymorphic: true
  belongs_to :project, optional: true
  has_many :email_logs, dependent: :destroy

  # Enums
  enum :state, {
    queued: 'queued',
    sent: 'sent',
    delivered: 'delivered',
    read: 'read',
    archived: 'archived'
  }, prefix: true

  enum :channel, {
    in_app: 'in_app',
    email: 'email'
  }, prefix: true

  enum :priority, {
    low: 'low',
    normal: 'normal',
    high: 'high',
    critical: 'critical'
  }, prefix: true

  # Build the enum map dynamically from the VALID_EVENT_TYPES constant
  enum :event_type, VALID_EVENT_TYPES.index_by(&:to_sym), prefix: true

  # Validations
  validates :group_key, presence: true
  validates :group_count, numericality: { greater_than: 0 }
  validates :score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :dedupe_fingerprint, presence: true, uniqueness: { scope: %i[recipient_id channel] }
  validates :first_event_at, presence: true
  validates :last_event_at, presence: true

  # Scopes
  scope :unread, -> { where(state: %i[queued sent delivered]) }
  scope :read, -> { state_read }
  scope :inbox, -> { where.not(state: :archived) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(recipient: user) }
  scope :high_priority, -> { where(priority: %i[high critical]) }
  scope :today, -> { where(created_at: Date.current.all_day) }
  # Time.current, not Date.current: Date#end_of_week is a DATE, and Rails binds it as
  # midnight, so the whole last day of the week fell outside the range. The scope was
  # correct six days out of seven and silently wrong on the seventh - which is also why
  # its spec only went red on a Sunday. Time#all_week ends at 23:59:59.999999, the same
  # shape the :today scope beside it already had via Date#all_day.
  scope :this_week, -> { where(created_at: Time.current.all_week) }
  scope :grouped, -> { where('group_count > ?', 1) }
  # @-mentions of the recipient. Single source for the "mention" filter — reused by
  # Overview::MyMentionsComponent and the cross-org cockpit (Dashboard::CrossOrgActionSummary).
  scope :mentions, -> { where(event_type: Notifications::Constants::EVENT_TYPE_MENTION) }

  # Scope for tenant-safe queries
  scope :for_current_tenant_user, lambda { |user|
    where(recipient: user, organisation: ActsAsTenant.current_tenant)
  }

  # The area a notification belongs to, by the type of its subject: whoever may
  # not read that area does not receive, see or count it. The ONE mapping, read
  # by delivery (Notifications::FanoutService#gated_area_for) and by every inbox
  # surface (.readable). A type not named here (repository index outcomes, time
  # session groups) is measured against the whole project, a row without a
  # project (system messages) passes. Until 2026-10-07 the read side asked no
  # area at all, and delivery measured notes against documents.
  #
  # The PROJECT is not named here and not "whole project" either: it is the
  # subject of every event tracked on it (a ticket moved in or out, a bulk run, a
  # note or meeting created, a member added), and those events carry their
  # object's title, number or address in the payload. Such a row has the area of
  # its EVENT (PROJECT_EVENT_TYPE below, Activities::AreaRegistry). Until
  # 2026-10-08 it counted as whole project, and every member, subscribed to the
  # project on joining, read the moved tickets' titles through the token inbox.
  #
  # Guards: spec/services/notifications/area_rights_spec.rb,
  # project_event_area_spec.rb and fanout_service_area_gate_spec.rb. Plan:
  # lalabase-private doc/benachrichtigungen_bereichsrechte_plan.md.
  AREA_BY_NOTIFIABLE_TYPE = {
    'Ticket' => :tickets,
    'Note' => :notes,
    'Document' => :documents
  }.freeze

  # A notification about the project itself is about one of its events, and the
  # event names the area: payload['action'] is the event's action, the key in
  # Activities::AreaRegistry is "project.<action>".
  PROJECT_EVENT_TYPE = 'Project'

  # The area of an event nobody has placed in the registry: no reader has it, so
  # nobody receives or sees the row (the registry's own rule, nil = drop).
  UNMAPPED_EVENT = :unmapped_event

  # nil = the whole project; UNMAPPED_EVENT = nobody.
  def self.area_for(notifiable, action: nil)
    return AREA_BY_NOTIFIABLE_TYPE[notifiable&.class&.name] unless notifiable.is_a?(Project)

    area = Activities::AreaRegistry.area_for("project.#{action}")
    return UNMAPPED_EVENT if area.nil?

    area == Activities::AreaRegistry::PROJECT_LEVEL ? nil : area
  end

  # The projects whose notifications `user` may still see in `organisation`:
  # the ACTIVE projects they may read, in `area` (nil: in any area). The ONE
  # definition behind every inbox surface (cockpit tile, nav badge, org
  # switcher, inbox list, token inbox, mail gate). Until 2026-10-02 the cockpit
  # asked for active projects and the rest did not, so an account admin, the
  # one role that still reaches an archived project, saw a different number on
  # the tile than in the inbox it led to. Guard:
  # spec/services/notifications/unread_count_parity_spec.rb.
  #
  # A relation, not plucked ids, and the organisation is passed explicitly:
  # Notifications::InboxQuery asks this for several organisations from inside
  # ActsAsTenant.without_tenant. The tenant still matters while the relation is
  # BUILT: a tenant set to another organisation empties it silently, none set
  # (outside without_tenant) raises NoTenantSet. Every caller sets the matching
  # tenant or none on purpose.
  #
  # Resolved once per request per (user, organisation, area) (Current memo):
  # the layout alone asks for it three times per page.
  def self.source_projects_for(user, organisation, area: nil)
    Current.notification_source_projects(user, organisation, area) do
      AccessCheck::ProjectAccessService.accessible_projects(user, organisation, area: area).active
    end
  end

  # The rows of `rel` that `user` may see in `organisation`: no project; or a
  # project they may read in any area, for a subject the mapping does not name;
  # or, per named type, a project they may read in THAT area; or, for an event
  # on the project, a project they may read in the area of that event (any area
  # for project news, none for an event without a rule). `within` narrows every
  # project set further (a token's projects). Derived, never stored: getting a
  # right back brings the rows back.
  def self.readable(rel, user, organisation, within: nil)
    sources = lambda do |area|
      projects = source_projects_for(user, organisation, area: area)
      projects = projects.where(id: within) if within
      projects.select(:id)
    end
    named = AREA_BY_NOTIFIABLE_TYPE.keys + [PROJECT_EVENT_TYPE]
    whole_project = rel.where(project_id: sources.call(nil))
    condition = rel.where(project_id: nil)
                   .or(whole_project.where.not(notifiable_type: named))
                   .or(whole_project.where(notifiable_type: nil))
    AREA_BY_NOTIFIABLE_TYPE.each do |type, area|
      condition = condition.or(rel.where(notifiable_type: type, project_id: sources.call(area)))
    end
    Activities::AreaRegistry.project_actions_by_area.each do |area, actions|
      area = nil if area == Activities::AreaRegistry::PROJECT_LEVEL
      condition = condition.or(rel.where(notifiable_type: PROJECT_EVENT_TYPE, project_id: sources.call(area))
                                  .where(payload_action.in(actions)))
    end
    condition
  end

  # payload->>'action', as Arel: the event a row about the project reports.
  def self.payload_action
    Arel::Nodes::InfixOperation.new('->>', arel_table[:payload], Arel::Nodes.build_quoted('action'))
  end
  private_class_method :payload_action

  # Restricted to notifications the user can see in the org (.readable). Keeps
  # counts from counting orphans of lost project or area access.
  scope :accessible_for, lambda { |user, organisation|
    Notification.readable(self, user, organisation)
  }

  # What the inbox of `organisation` counts as unread for `user`: the ONE rule
  # behind the cockpit tile, the nav badge (User#unread_notifications_count),
  # the mobile nav, the bell dropdown and the org switcher
  # (Notifications::UnreadSignals). They once differed, and the switcher showed
  # a smaller number than the inbox it led to.
  scope :inbox_unread, lambda { |user, organisation|
    where(recipient: user, organisation: organisation).channel_in_app.unread.accessible_for(user, organisation)
  }

  # PERFORMANCE OPTIMIZED SCOPES - Prevent N+1 queries
  scope :with_users, -> { includes(:recipient, :actor) }
  scope :with_email_logs, -> { includes(:email_logs) }
  scope :with_full_context, -> { includes(:recipient, :actor, :email_logs, :notifiable) }

  # Admin/display contexts
  scope :for_admin_display, lambda {
    includes(:recipient, :actor, :email_logs, :organisation, :notifiable)
  }

  # Email log counts without N+1 (for dashboard/stats)
  scope :with_email_log_counts, lambda {
    left_joins(:email_logs)
      .group('notifications.id')
      .select('notifications.*, COUNT(email_logs.id) as email_logs_count')
  }

  # Filter scopes for notification center
  scope :for_project, ->(project_id) { where(project_id: project_id) if project_id.present? }
  scope :with_state_filter, lambda { |state|
    return all if state.blank?

    normalized = state.to_s

    if normalized == 'unread'
      where(state: %w[queued sent delivered])
    elsif states.key?(normalized)
      where(state: normalized)
    else
      all
    end
  }
  scope :with_event_type, ->(event_type) { where(event_type: event_type) if event_type.present? }

  # What an inbox row is about and shows as its title, by type and column.
  SEARCH_TITLES = { 'Ticket' => :title, 'Meeting' => :title }.freeze

  # The inbox search finds what a row shows: the title of what it is about,
  # the project, the name of who did it (never an address: it may be a login
  # address hidden from others). Until 2026-11-10 it searched the payload's
  # JSON text (an activity id, the action's name), which missed the title and
  # found every comment for "post". Guard: spec/models/notification_search_spec.rb.
  scope :search, lambda { |query|
    term = query.to_s.strip
    return all if term.blank?

    pattern = "%#{sanitize_sql_like(term)}%"
    users = User.arel_table
    whole_name = Arel::Nodes::NamedFunction.new('CONCAT_WS', [Arel::Nodes.build_quoted(' '),
                                                              users[:first_name], users[:last_name]])
    matches = where(project_id: Project.where(Project.arel_table[:name].matches(pattern)).select(:id))
              .or(where(actor_id: User.where(whole_name.matches(pattern)).select(:id)))
    SEARCH_TITLES.reduce(matches) do |relation, (type, column)|
      klass = type.constantize
      relation.or(where(notifiable_type: type,
                        notifiable_id: klass.where(klass.arel_table[column].matches(pattern)).select(:id)))
    end
  }

  # The inbox's period filter: the time area's presets (TimeSessions::ListPeriod,
  # one vocabulary for "diese Woche" and its bounds), a notification counted
  # by the day it arrived in the reader's zone. "all" and an unknown key are
  # no window. Guard: spec/requests/inbox_period_filter_spec.rb.
  scope :created_in_period, lambda { |key, time_zone: Time.zone|
    zone = time_zone || Time.zone
    period = TimeSessions::ListPeriod.normalize_for_table(key)
    from, to = TimeSessions::ListPeriod.bounds_for(period, today: Time.current.in_time_zone(zone).to_date)
    next all unless from && to

    where(created_at: zone.local(from.year, from.month, from.day)..zone.local(to.year, to.month, to.day).end_of_day)
  }

  # Date grouping scope with database-level grouping
  scope :grouped_by_date, lambda {
    order('DATE(created_at) DESC, created_at DESC')
  }

  # Performance-optimized scope for notification center.
  # avatar_attachment/blob: every row draws the actor through
  # Neo::Users::NameComponent in circle mode, whose attached? check is one
  # query per actor without the preload (S2, doc/user_display_name_avatar_plan.md).
  scope :for_notification_center, lambda {
    includes(:notifiable, :project, actor: { avatar_attachment: :blob })
  }

  # Combined filter scope
  scope :apply_filters, lambda { |filters|
    return all if filters.blank?

    relation = all
    relation = relation.for_project(filters[:project_id]) if filters[:project_id].present?
    relation = relation.with_state_filter(filters[:state]) if filters[:state].present?
    relation = relation.with_event_type(filters[:event_type]) if filters[:event_type].present?
    relation = relation.search(filters[:search]) if filters[:search].present?
    relation
  }

  # Callbacks
  before_validation :set_timestamps, on: :create
  # Org switcher signal (Notifications::UnreadSignals): every change that makes
  # an in-app notification unread or no longer unread. after_save notes it for
  # EACH save, so a second save in the same transaction cannot hide the first
  # (after_commit alone only sees the last save's changes). Bulk changes skip
  # these callbacks and go through .bulk_transition!, which refreshes instead.
  after_save :note_unread_signal_change
  after_destroy :note_unread_signal_removal
  after_commit :refresh_unread_signals, if: :unread_signal_pending?
  after_rollback :forget_unread_signal

  # The one way to change states in bulk, called on a relation:
  #   scope.unread.bulk_transition!(state: 'read', read_at: Time.current)
  # update_all skips after_commit, so this refreshes the org switcher signal of
  # every recipient whose touched rows carry one. The rows are fixed ONCE: the
  # update runs on the relation AND those ids, so a row created between the
  # read and the write is neither changed nor missed, and order/limit on the
  # relation stay harmless. Returns the number of rows changed.
  # Guard: spec/models/notification_bulk_transition_guard_spec.rb.
  def self.bulk_transition!(**attributes)
    rows = pluck(:id, :recipient_id, :channel)
    return 0 if rows.empty?

    changed = where(id: rows.map(&:first)).update_all(attributes)
    if changed.positive?
      rows.filter_map { |_id, recipient_id, channel| recipient_id if channel.to_s == 'in_app' }
          .uniq
          .each { |recipient_id| Notifications::UnreadSignals.refresh_later(recipient_id) }
    end
    changed
  end

  # Instance methods
  def mark_as_read!
    return if state_read? || state_archived?

    update!(state: :read, read_at: Time.current)
  end

  def mark_as_delivered!
    return unless state_queued? || state_sent?

    update!(state: :delivered, delivered_at: Time.current)
  end

  def mark_sent!
    return unless state_queued?

    update!(state: :sent, sent_at: Time.current)
  end

  def mark_failed!
    # Keep in queued state for retry, but log the failure
    touch(:updated_at)
  end

  def archive!
    update!(state: :archived, archived_at: Time.current)
  end

  def mark_as_archived!
    archive!
  end

  def mark_as_unread!
    return if state_archived?

    update!(state: :queued, read_at: nil)
  end

  def restore_from_archived!
    return unless state_archived?

    update!(state: :queued, read_at: nil, archived_at: nil)
  end

  def unread?
    !state_read? && !state_archived?
  end

  def grouped?
    group_count > 1
  end

  def high_priority?
    priority_high? || priority_critical?
  end

  def should_send_immediately?
    high_priority? || IMMEDIATE_DELIVERY_EVENTS.include?(event_type)
  end

  private

  UNREAD_STATES = %w[queued sent delivered].freeze
  private_constant :UNREAD_STATES

  def note_unread_signal_change
    @unread_signal_pending = true if unread_signal_changed?
  end

  def note_unread_signal_removal
    @unread_signal_pending = true if Notifications::UnreadSignals.signal?(self) && unread?
  end

  def unread_signal_pending?
    @unread_signal_pending == true
  end

  def forget_unread_signal
    @unread_signal_pending = false
  end

  # Called from after_save, so the saved_change_* readers describe THIS save.
  def unread_signal_changed?
    return false unless Notifications::UnreadSignals.signal?(self)
    return unread? if saved_change_to_id?

    before, after = saved_change_to_state
    return false if before.nil? && after.nil?

    UNREAD_STATES.include?(before) != UNREAD_STATES.include?(after)
  end

  def refresh_unread_signals
    @unread_signal_pending = false
    Notifications::UnreadSignals.refresh_later(recipient_id)
  end

  def set_timestamps
    self.first_event_at ||= Time.current
    self.last_event_at ||= Time.current
  end
end
