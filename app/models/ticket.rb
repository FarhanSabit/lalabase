# frozen_string_literal: true

# Read path map for this whole area: docs/architektur/tickets_lesepfad.md
#
# Status and priority are NOT columns and NOT foreign keys — the ticket_statuses and
# ticket_priorities tables are gone. Both are strings inside the custom_attributes JSONB,
# with the allowed values configured per project in TicketAttributeDefinition. Whether a
# status counts as "done" is decided by the system functions attached to that option, so
# never compare status strings literally — use #done? or
# TicketAttributeDefinition.closed_status_values_for.
#
# == Schema Information
#
# Table name: tickets
#
#  id                       :uuid             not null, primary key
#  custom_attributes        :jsonb            not null
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  number                   :integer
#  summary                  :text
#  summary_generated_at     :datetime
#  ticket_type              :string           default("support"), not null
#  title                    :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  creator_id               :uuid             not null
#  organisation_id          :uuid             not null
#  parent_id                :uuid
#  project_id               :uuid             not null
#  updater_id               :uuid
#
# Indexes
#
#  index_tickets_on_creator_id                       (creator_id)
#  index_tickets_on_custom_attributes                (custom_attributes) USING gin
#  index_tickets_on_custom_attrs_not_null            (((custom_attributes IS NOT NULL))) WHERE (custom_attributes IS NOT NULL)
#  index_tickets_on_org_and_custom_attrs_exists      (organisation_id, ((custom_attributes IS NOT NULL)))
#  index_tickets_on_org_created                      (organisation_id,created_at)
#  index_tickets_on_organisation_id_and_ticket_type  (organisation_id,ticket_type)
#  index_tickets_on_parent_id                        (parent_id)
#  index_tickets_on_project_and_custom_attrs_exists  (project_id, ((custom_attributes IS NOT NULL)))
#  index_tickets_on_project_created                  (project_id,created_at)
#  index_tickets_on_project_creator                  (project_id,creator_id)
#  index_tickets_on_project_id_and_number            (project_id,number) UNIQUE
#  index_tickets_on_project_title                    (project_id,title)
#  index_tickets_on_project_updated                  (project_id,updated_at)
#  index_tickets_on_ticket_type                      (ticket_type)
#  index_tickets_title_fts                           (to_tsvector('german'::regconfig, (title)::text)) USING gin
#
# Foreign Keys
#
#  fk_rails_...  (parent_id => tickets.id) ON DELETE => nullify
#
class Ticket < ApplicationRecord
  include Taggable
  include OneLineText
  include TicketTrackable
  include CustomAttributable
  acts_as_tenant(:organisation)

  belongs_to :project
  has_many :posts, dependent: :destroy
  has_many :ticket_documents, dependent: :destroy
  # Assignments
  has_many :ticket_assignments, dependent: :destroy
  has_many :assignees, through: :ticket_assignments, source: :user

  belongs_to :creator, class_name: 'User', optional: true
  belongs_to :updater, class_name: 'User', optional: true

  # Notification subscriptions (polymorphic)
  has_many :notification_subscriptions, as: :subscribable, dependent: :destroy

  # ActionText for rich content
  has_rich_text :content
  include RichTextEmbedGuard

  # Flag to skip auto-subscribe during bulk import (prevents N+1 queries)
  attr_accessor :skip_auto_subscribe

  # The bound of Project::NAME_MAX_LENGTH and MeetingTicketSuggestion#title.
  # Checked only on a CHANGED title: titles from before the bound keep saving
  # every other change. Without it a long title failed in PostgreSQL on the
  # (project_id, title) btree index, as an internal error.
  TITLE_MAX_LENGTH = 255

  validates :title, presence: true
  validates :title, length: { maximum: TITLE_MAX_LENGTH }, if: :title_changed?
  validates :number, uniqueness: { scope: :project_id }, allow_nil: true
  validate :number_presence_after_create, on: :update

  # Auto-assign number before creation
  before_create :assign_next_number
  after_create_commit :auto_subscribe_creator

  # Fragments for embeddings
  has_many :fragments, as: :fragmentable, dependent: :delete_all

  # Import tracking
  has_many :imported_objects, as: :importable, dependent: :destroy

  has_many :time_sessions, dependent: :nullify

  # Sub-tasks: self-referential, any depth (parent -> children -> grandchildren ...). A ticket
  # gets its parent when it is created and keeps it: the validations below refuse any later
  # change, so a cycle cannot be built (a new ticket has no descendants to close one with).
  # `dependent: :nullify` ORPHANS children on parent delete (they survive as top-level
  # tickets, their own children stay attached), mirrored at the DB level by the FK
  # on_delete: :nullify; it writes past validations, which is why the fixed parent does not
  # block it. Destroying a child's logged time/comments would be data loss (sub-tasks
  # design, premise 4).
  belongs_to :parent, class_name: 'Ticket', optional: true
  has_many :children, class_name: 'Ticket', foreign_key: :parent_id, inverse_of: :parent, dependent: :nullify

  # Typed relations to other tickets of the organisation (TicketRelation): this ticket is the
  # source of its outgoing and the target of its incoming rows. The database cascades as well
  # (ON DELETE CASCADE on both keys); delete_all only saves loading the rows. Whether a ticket
  # waits is Tickets::Waiting's question, not a query on these associations.
  has_many :outgoing_relations, class_name: 'TicketRelation', foreign_key: :source_ticket_id,
                                inverse_of: :source_ticket, dependent: :delete_all
  has_many :incoming_relations, class_name: 'TicketRelation', foreign_key: :target_ticket_id,
                                inverse_of: :target_ticket, dependent: :delete_all

  # Tickets without a parent. Prepared for a future list/board "nesting" view; not yet
  # applied to any counter in v1 (open children intentionally count as real work).
  scope :top_level, -> { where(parent_id: nil) }

  # Sub-task invariants. parent_id is attacker-controllable, so these run server-side on
  # every write through SaveTicket. acts_as_tenant scopes the `parent` load, so a foreign-org
  # parent loads as nil -> rejected as :not_found (cross-tenant is a subset of cross-project,
  # since project_ids are globally unique, but we reject not-found explicitly rather than
  # letting `optional: true` swallow a dangling reference). Depth is not limited; instead the
  # parent is fixed once the ticket exists (parent_unchanged), which keeps the tree acyclic.
  validate :parent_not_self
  validate :parent_loadable_and_same_project
  validate :parent_unchanged, on: :update

  include PgSearch::Model
  # Title and description, what every reader of the ticket may read. Never add `posts` to
  # associated_against: a pg_search join cannot ask Post.readable_by, so a hidden private
  # comment would make its ticket a hit, and prefix matching spells out its words. Until
  # 2026-11-05 it did, in the ticket list of REST and MCP
  # (spec/requests/api/ticket_list_search_private_comments_spec.rb). A search over comments
  # joins the readable ones only, as TicketSearchQuery#readable_posts_join does.
  pg_search_scope :search_title_and_description, using: { tsearch: { prefix: true } },
                                                 against: [:title],
                                                 associated_against: { rich_text_content: [:body] }

  # The title alone, same settings. For a picker that lists tickets from several projects
  # (Tickets::Lookup).
  pg_search_scope :search_title, using: { tsearch: { prefix: true } }, against: [:title]

  # Plain text version for embeddings
  def plain_text_version
    "#{title}\n#{content&.to_plain_text || ''}"
  end

  def create_embeddings?
    true # Tickets always have embeddings (no create_embeddings column like Note/Post/DocumentVersion)
  end

  # Filters candidate user ids down to those who may be assigned to this ticket: ACTIVE
  # members with access to the ticket's project (Project#assignable_users), plus whoever
  # is assigned already. Org membership alone is NOT enough, otherwise a project-foreign
  # org member could be linked via parameter tampering. A person who stays assigned is no
  # new request: without that, the edit form (which sends the whole list) dropped a
  # deactivated assignee on every save, and the board refused every addition beside one.
  # Single source for the web (Actors::SaveTicket), API (Api::V1::TicketsController) and
  # board/terminal (Tickets::Changes::AddRemoveAssignees) assignee write paths.
  def assignable_user_ids(candidate_ids)
    ids = Array(candidate_ids).compact.reject(&:blank?).map(&:to_s).uniq
    return [] if ids.empty? || project.nil?

    kept = persisted? ? ticket_assignments.where(user_id: ids).pluck(:user_id) : []
    project.assignable_users.where(id: ids).pluck(:id) | kept
  end

  def self.text_search(query)
    if query.present?
      search_title_and_description(query)
    else
      all
    end
  end

  # Display title with number prefix
  def display_title
    "##{number} #{title}"
  end

  # The display title as ONE line, cut to `max`. Two surfaces need this and they
  # need it bounded differently: the assistant's system prompt writes it into a
  # sentence, the reference chip has 380px of panel. So the NUMBER belongs to the
  # caller and the FORM to OneLineText, shared with Project#one_line_name.
  def one_line_title(max:)
    one_line(display_title, max:)
  end

  # Sub-task progress for the parent detail page: { done:, total:, percent: } or nil when childless.
  # "done" reuses the per-project status System Functions (is_completed/is_closed) via
  # closed_status_values_for — a child with no/untriaged status counts as not-done, and a
  # project that tags no status as closed simply yields done: 0.
  #
  # `percent` is integer-floored (1/3 -> 33). We compute it HERE rather than in the view so the
  # progress-bar width is unit-testable and the view stays free of arithmetic; total is never
  # zero past the guard, so there is no division-by-zero. Detail-page only — do NOT call per row
  # in a list (it runs two COUNTs + a status-values lookup -> N+1).
  def children_progress
    total = children.count
    return nil if total.zero?

    done_values = TicketAttributeDefinition.closed_status_values_for([project_id])
    done = children.with_status_values(done_values).count
    { done: done, total: total, percent: done * 100 / total }
  end

  # Search by ticket number within project
  def self.find_by_number(project, number)
    where(project: project, number: number).first
  end

  # Scopes for ordering
  scope :ordered_by_number, -> { order(:number) }
  scope :ordered_by_number_desc, -> { order(number: :desc) }

  # Priority sorting from custom_attributes->>'priority' (multilingual values).
  # Lower number = more urgent; secondarily by recency (most recently changed first).
  PRIORITY_ORDER_SQL = "CASE LOWER(custom_attributes->>'priority') " \
    "WHEN 'urgent' THEN 0 WHEN 'dringend' THEN 0 WHEN 'critical' THEN 0 WHEN 'kritisch' THEN 0 " \
    "WHEN 'high' THEN 1 WHEN 'hoch' THEN 1 " \
    "WHEN 'normal' THEN 2 WHEN 'medium' THEN 2 WHEN 'mittel' THEN 2 " \
    "WHEN 'low' THEN 3 WHEN 'niedrig' THEN 3 WHEN 'gering' THEN 3 " \
    'ELSE 4 END, tickets.updated_at DESC'

  scope :by_priority, -> { order(Arel.sql(PRIORITY_ORDER_SQL)) }

  # Priority values that count as "high / very high" (the urgent + high tiers).
  # MUST stay consistent with the WHEN 0 / WHEN 1 branches of PRIORITY_ORDER_SQL above. This is a
  # separate constant on purpose: generating the ORDER-BY CASE from arrays would touch a hot,
  # well-tested multilingual sort for marginal DRY, so we accept the small duplication and pin it
  # with this comment. Values are lowercase; the scope matches case-insensitively.
  HIGH_PRIORITY_VALUES = %w[urgent dringend critical kritisch high hoch].freeze

  # Tickets whose priority is high or very high (see HIGH_PRIORITY_VALUES). Reused by the cockpit's
  # "important" importance level, where the shown set is "overdue OR high priority".
  scope :high_priority, lambda {
    where("LOWER(custom_attributes->>'priority') IN (?)", HIGH_PRIORITY_VALUES)
  }

  # JSONB select attributes that sort by their CONFIGURED option order (per project)
  # instead of alphabetically. Generic by design: append another select-attribute key
  # here and register it in the controller to make it sortable the same way.
  SORTABLE_CUSTOM_ATTRIBUTES = %w[status priority due_date].freeze

  # The deadline custom-attribute key. v1 pins the SQL/JSON key (sort + overdue) to this
  # fixed name; the per-field `deadline` marker (TicketAttributeDefinition) is a feature
  # flag + v2 generalization seam, NOT the SQL key. See doc/faelligkeit_due_date_plan.md §11.
  DUE_DATE_KEY = 'due_date'

  # View column keys for custom attributes carry a 'custom_' prefix (e.g. the
  # priority column's key is 'custom_priority'). The sort param therefore arrives
  # prefixed from the header link; bare keys are accepted too for robustness.
  CUSTOM_COLUMN_PREFIX = 'custom_'

  # Maps a sort column key to the JSONB attribute name when it is a sortable custom
  # attribute, otherwise nil. Accepts both 'custom_priority' and bare 'priority'.
  def self.sortable_custom_attribute(column_key)
    name = column_key.to_s.delete_prefix(CUSTOM_COLUMN_PREFIX)
    SORTABLE_CUSTOM_ATTRIBUTES.include?(name) ? name : nil
  end

  # All sort column keys that map to a custom attribute (bare + prefixed), so the
  # controller can whitelist them in the Sortable concern.
  def self.sortable_custom_attribute_keys
    SORTABLE_CUSTOM_ATTRIBUTES.flat_map { |name| [name, "#{CUSTOM_COLUMN_PREFIX}#{name}"] }
  end

  # Builds a deterministic ORDER BY for a JSONB select attribute that follows the
  # configured option order. `ordered_values` are the option value keys in display
  # order (see TicketAttributeDefinition#ordered_value_keys). Unknown/blank values
  # always sort LAST regardless of direction; ties broken by most-recently-updated.
  # All dynamic values are quoted via the connection — safe against injection.
  def self.custom_attribute_order_sql(attr_name, ordered_values, direction = 'asc')
    conn = connection
    value_expr = "LOWER(custom_attributes->>#{conn.quote(attr_name.to_s)})"
    dir = direction.to_s.downcase == 'desc' ? 'DESC' : 'ASC'

    # No configuration to order by → stable alphabetical fallback, blanks last.
    return "#{value_expr} #{dir} NULLS LAST, tickets.updated_at DESC" if ordered_values.blank?

    quoted = ordered_values.map { |value| conn.quote(value.to_s.downcase) }
    whens = quoted.each_with_index.map { |qv, index| "WHEN #{qv} THEN #{index}" }.join(' ')
    # Known values keep configured order; everything else (unknown/NULL) is bucketed last.
    known_bucket = "CASE WHEN #{value_expr} IN (#{quoted.join(', ')}) THEN 0 ELSE 1 END"
    position = "CASE #{value_expr} #{whens} ELSE #{ordered_values.size} END"

    "#{known_bucket} ASC, #{position} #{dir}, tickets.updated_at DESC"
  end

  # Orders tickets by a configured JSONB select attribute (e.g. status, priority).
  scope :ordered_by_custom_attribute, lambda { |attr_name, ordered_values, direction = 'asc'|
    reorder(Arel.sql(custom_attribute_order_sql(attr_name, ordered_values, direction)))
  }

  # ORDER BY for a JSONB date attribute. ISO YYYY-MM-DD strings sort lexicographically =
  # chronologically, so no ::date cast is needed (robust: never raises on legacy garbage).
  # NULLIF maps empty strings to NULL so blanks sort LAST in both directions; ties broken
  # by most-recently-updated. attr_name is quoted via the connection — safe against injection.
  def self.date_attribute_order_sql(attr_name, direction = 'asc')
    expr = "NULLIF(custom_attributes->>#{connection.quote(attr_name.to_s)}, '')"
    dir  = direction.to_s.downcase == 'desc' ? 'DESC' : 'ASC'
    "#{expr} #{dir} NULLS LAST, tickets.updated_at DESC"
  end

  # Single sort-dispatch for custom attributes: a `date` field sorts chronologically, any
  # other (select) field sorts by its configured option order. One definition lookup, shared
  # by both sort call sites (TicketsController#apply_sorting and SortableQuery) so the
  # date-vs-select branch can never drift between them.
  def self.custom_attribute_sort_sql(attr_name, project, direction = 'asc')
    definition = TicketAttributeDefinition.active.find_by(project: project, name: attr_name)
    if definition&.field_type == 'date'
      date_attribute_order_sql(attr_name, direction)
    else
      custom_attribute_order_sql(attr_name, definition&.ordered_value_keys || [], direction)
    end
  end

  # Excludes tickets whose status value is in the given list (downcased).
  # Empty array → no filter (all tickets). NULL/absent status is KEPT: a plain
  # `NOT IN` drops NULL rows (NULL IN (...) is NULL, NOT NULL is NULL), but an
  # untriaged ticket is not parked — it must survive the exclusion.
  scope :excluding_status_values, lambda { |values|
    values.present? ? where("custom_attributes->>'status' IS NULL OR LOWER(custom_attributes->>'status') NOT IN (?)", values) : all
  }

  # The positive complement of excluding_status_values: only tickets WITH one of the
  # given status values. Empty list → none (a "done count" over zero done-statuses is 0,
  # not "all"). Kept as a pair so the status-value SQL lives in one place.
  scope :with_status_values, lambda { |values|
    values.present? ? where("LOWER(custom_attributes->>'status') IN (?)", values) : none
  }

  # Tickets assigned to the given user (via the ticket_assignments join). Single source for
  # the "assigned to me" definition — reused by Overview::MyOpenTicketsComponent and the
  # cross-org cockpit (Dashboard::CrossOrgActionSummary) so they cannot drift apart.
  scope :assigned_to, ->(user) { joins(:ticket_assignments).where(ticket_assignments: { user_id: user.id }) }

  # "Active work": excludes tickets parked in a backlog status (is_backlog).
  # The project scope is DERIVED from the current relation (no project_ids arg) so a
  # call site cannot silently pass the wrong ids — e.g. project.tickets.active_work.
  # Backlog values per project come from the status attribute's System Functions.
  #
  # Why unscope(:select, :order, :limit, :offset) before plucking project_ids: the scope
  # may be chained after .select/.order/.limit/.offset (e.g. recent_tickets), and we want
  # the project_ids of the WHOLE relation, not of a limited/ordered window — distinct.pluck
  # would otherwise inherit those clauses and derive the wrong (or an erroring) id set.
  #
  # NOTE: closed/completed tickets are intentionally NOT excluded here (scope = backlog
  # only). nil-status tickets stay "active" (untriaged is not the same as backlog).
  scope :active_work, lambda {
    project_ids = unscope(:select, :order, :limit, :offset).distinct.pluck(:project_id)
    excluding_status_values(TicketAttributeDefinition.backlog_status_values_for(project_ids))
  }

  # Overdue: a due date strictly before today AND the ticket is not in a closed/completed
  # status. Mirrors active_work: project_ids are DERIVED from the relation (no arg → no
  # wrong-id foot-gun) and closed status VALUES come per-project from the status System
  # Functions. The `<> ''` guard is essential — an empty string is not NULL and `'' < date`
  # would be a false overdue. excluding_status_values KEEPS NULL/untriaged status (an
  # untriaged but past-due ticket IS overdue). Like active_work, status VALUES are matched
  # globally across the relation's projects (e.g. 'closed' means closed everywhere).
  # The raw "due date is strictly before today" predicate, with NO status exclusion. This is the
  # ONE place the past-due date SQL lives (the `<> ''` guard stops an empty string from sorting
  # before any real date). `overdue` = this + closed-exclusion. The cockpit's :important filter
  # reuses `due_in_past` DIRECTLY (not `overdue`) because its base set is already active (assigned,
  # not closed/backlog), so re-excluding closed would be redundant — and `overdue` plucks project_ids
  # (an extra query per org) which the cockpit must avoid. Keep "overdue" and "due_in_past" in sync
  # by composing one from the other, never by duplicating the date SQL.
  scope :due_in_past, lambda {
    where("custom_attributes->>'due_date' IS NOT NULL AND custom_attributes->>'due_date' <> '' " \
          "AND custom_attributes->>'due_date' < ?", Date.current.iso8601)
  }

  scope :overdue, lambda {
    project_ids = unscope(:select, :order, :limit, :offset).distinct.pluck(:project_id)
    closed_values = TicketAttributeDefinition.closed_status_values_for(project_ids)
    due_in_past.excluding_status_values(closed_values)
  }

  # Tickets whose due date falls within [from, to] (inclusive). ISO text compare + the same
  # `<> ''` guard as #overdue (an empty string would otherwise sort before any real date). Pinned
  # to DUE_DATE_KEY in v1. This is the ONE place the forward-looking due-date range SQL lives —
  # the FilterBar quick-filter, the SmartFolder relative operators, and any due-date widget all
  # go through here, so "due this week" means exactly the same thing everywhere.
  scope :due_within, lambda { |from, to|
    where("custom_attributes->>'due_date' <> '' AND custom_attributes->>'due_date' BETWEEN ? AND ?",
          from.to_date.iso8601, to.to_date.iso8601)
  }

  # Canonical set of relative due-date presets. ONE source of truth, referenced by the SmartFolder
  # relative operators (SmartFolderRule), the FilterBar quick-filter (AdHocFilterHelper/Service), and
  # any due-date widget — so adding/removing a preset is a single-line change, not a 4-file hunt.
  # (The Stimulus form controller keeps its own copy across the JS/Ruby boundary — keep them in sync.)
  DUE_DATE_PRESET_KEYS = %w[overdue due_today due_this_week due_next_7_days].freeze

  # Forward-looking [from, to] date range for a RANGE preset. `overdue` returns nil — it is not a
  # plain range (it also excludes closed tickets), so callers use the `overdue` scope for it. Single
  # source of truth for what each preset means, shared by the FilterBar and the SmartFolder.
  def self.due_date_preset_range(preset)
    case preset
    when 'due_today'       then [Date.current, Date.current]
    when 'due_this_week'   then [Date.current, Date.current.end_of_week]
    when 'due_next_7_days' then [Date.current, Date.current + 7]
    end
  end

  # Apply a relative due-date preset to a ticket relation (overdue → the overdue scope, otherwise the
  # range scope). Shared by both filter surfaces so a preset filters identically in each.
  scope :matching_due_preset, lambda { |preset|
    preset == 'overdue' ? overdue : due_within(*Ticket.due_date_preset_range(preset))
  }

  # Order by due date (default ascending = most urgent first), blanks/no-date last. Reuses the one
  # date-ordering SQL so due-date lists sort the same everywhere (e.g. the overview due-bucket widget).
  scope :order_by_due_date, lambda { |direction = 'asc'|
    reorder(Arel.sql(date_attribute_order_sql(DUE_DATE_KEY, direction)))
  }

  # Scope for recently updated tickets (for performance in selects)
  scope :open_or_recent, lambda {
    where('tickets.updated_at > ?', 30.days.ago)
      .order(updated_at: :desc)
  }

  # Parsed deadline date, or nil. Strict ISO parse: legacy/garbage values yield nil rather
  # than raising. Write-time validation (TicketAttributeDefinition#validate_date_value)
  # prevents NEW garbage; this rescue guards rows written before that validation existed.
  def due_on
    raw = custom_attributes[DUE_DATE_KEY]
    return nil if raw.blank?

    Date.iso8601(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Overdue = due strictly before today AND not done. Done tickets are never flagged, so
  # completed work does not nag. Boundary: due today is NOT overdue.
  def overdue?
    date = due_on
    return false if date.nil?

    date < Date.current && !done?
  end

  # True when the ticket's status carries a closed/completed System Function (per project).
  def done?
    TicketAttributeDefinition::CLOSED_SYSTEM_FUNCTIONS.any? { |fn| has_system_function?(fn) }
  end

  private

  def assign_next_number
    return if number.present?

    # Advisory lock serializes number assignment per project, preventing
    # TOCTOU race conditions where two concurrent INSERTs read the same
    # maximum(:number) and both try to use max + 1.
    # The lock is automatically released when the enclosing transaction commits.
    lock_key = Zlib.crc32("ticket_number:#{project_id}")
    self.class.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")

    max_number = self.class.where(project: project).maximum(:number) || 0
    self.number = max_number + 1
  end

  def auto_subscribe_creator
    return if skip_auto_subscribe
    return unless creator
    return unless creator.ticket_auto_follow_created?

    NotificationSubscription.system_subscribe(user: creator, item: self, source: NotificationSubscription::SOURCE_CREATOR)
  end

  def number_presence_after_create
    errors.add(:number, :blank) if number.blank?
  end

  # --- Sub-task invariants -------------------------------------------------

  def parent_not_self
    errors.add(:parent_id, :cannot_be_self) if parent_id.present? && parent_id == id
  end

  # Two branches (both required): a parent_id that is present but not loadable under the
  # current tenant (foreign org, or deleted) must be REJECTED, not silently treated as
  # "no parent" by optional: true. A loadable parent in a different project is also rejected.
  def parent_loadable_and_same_project
    return if parent_id.blank?

    if parent.nil?
      errors.add(:parent_id, :not_found)
    elsif parent.project_id != project_id
      errors.add(:parent_id, :different_project)
    end
  end

  # A saved ticket keeps its parent: setting, replacing and clearing it are all refused.
  # Only a new ticket (no descendants yet) picks a parent, so no write can close a cycle.
  def parent_unchanged
    errors.add(:parent_id, :cannot_change) if will_save_change_to_parent_id?
  end
end

# ticket_type
#  - api
#  - refactoring
#  - bugfix
#  - feature

#  category
#   -
# assignee

# creator

# tags

# sequential number
