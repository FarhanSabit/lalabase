# frozen_string_literal: true

module UserDataExports
  # Single auditable source of truth for WHAT the personal data export
  # contains (GDPR Art. 15/20). Whitelist-only: the serializers emit exactly
  # the declared attributes/computed keys, never a full row.
  #
  #   SOURCES ──┬── tenant_scoped: false ──► one JSON file in the ZIP root,
  #             │                            queried directly (User, Membership, …
  #             │                            are not acts_as_tenant models)
  #             └── tenant_scoped: true  ──► one JSON file per organisation
  #                                          folder, queried inside
  #                                          ActsAsTenant.with_tenant(org) and
  #                                          ALWAYS owner-scoped on top
  #
  # Adding a data source = adding ONE entry here. Two guard specs enforce the
  # registry's integrity:
  # - registry_secret_guard_spec: no exported key may look like a secret
  # - registry_completeness_guard_spec: every table with a user reference must
  #   be listed here or in EXCLUDED (with a reason) — the export cannot drift
  #   into silent incompleteness when new tables appear
  #
  # Content boundaries (plan decisions, doc/user_data_export_plan.md):
  # - Option A: own structured data in full (time sessions, personal tasks),
  #   created content as INVENTORY (titles/dates, no bodies, no blobs)
  # - D9 role model: content in organisations belongs to the organisation as
  #   data controller; this export only covers orgs the user has a membership
  #   row for (incl. inactive) — ex-member content goes through the org admin.
  module Registry
    Source = Struct.new(:key, :model_name, :tenant_scoped, :attributes, :computed, :scope,
                        :serializer_class, keyword_init: true) do
      def model
        model_name.constantize
      end

      def zip_filename
        "#{key}.json"
      end

      def serializer
        (serializer_class || 'UserDataExports::GenericSerializer').constantize
      end

      # Keys this source emits — audited by the secret guard.
      def exported_keys
        if serializer_class
          serializer::ATTRIBUTES
        else
          Array(attributes) + computed.keys.map(&:to_s)
        end
      end
    end

    def self.source(key:, model:, tenant_scoped:, attributes: [], computed: {}, scope: nil, serializer: nil)
      Source.new(key: key, model_name: model, tenant_scoped: tenant_scoped,
                 attributes: attributes.map(&:to_s).freeze, computed: computed.freeze,
                 scope: scope, serializer_class: serializer)
    end
    private_class_method :source

    SOURCES = [
      # ── global (ZIP root) ────────────────────────────────────────────────
      source(key: :account, model: 'User', tenant_scoped: false,
             attributes: %w[email first_name last_name language_preference timezone
                            email_visibility contact_email
                            session_timeout_minutes active terms_accepted_at created_at
                            scheduled_deletion_at deletion_canceled_at deletion_recommended],
             scope: ->(user) { User.where(id: user.id) }),
      source(key: :memberships, model: 'Membership', tenant_scoped: false,
             serializer: 'UserDataExports::Serializers::MembershipsSerializer'),
      source(key: :security_history, model: 'UserActivity', tenant_scoped: false,
             serializer: 'UserDataExports::Serializers::UserActivitiesSerializer'),
      source(key: :api_tokens, model: 'PersonalAccessToken', tenant_scoped: false,
             attributes: %w[name token_prefix read_only last_used_at expires_at revoked_at created_at],
             scope: ->(user) { PersonalAccessToken.where(user: user) }),
      source(key: :notification_preferences, model: 'NotificationPreference', tenant_scoped: false,
             attributes: %w[scope_type enabled created_at],
             computed: { organisation_name: ->(r) { r.organisation&.name } },
             scope: ->(user) { NotificationPreference.where(user: user).includes(:organisation) }),
      # AI usage the user triggered (S3 KI-Kontingent). Global (AiUsage is NOT
      # acts_as_tenant — tenant_scoped: true would return cross-org rows in every
      # folder, which the tenant guard forbids). Personal attribution data only —
      # what/when/how-many-credits — deliberately WITHOUT cost_cents or metadata
      # (internal cost/margin statistics, not the user's personal data). Purpose of
      # the per-user link (quota transparency for org admins) is stated in the AI
      # opt-in explanation (_opt_in_explanation), DSGVO note plan §4.3.
      source(key: :ai_usages, model: 'AiUsage', tenant_scoped: false,
             attributes: %w[action credits_used used_at created_at],
             computed: { organisation_name: ->(r) { r.organisation&.name } },
             scope: ->(user) { AiUsage.where(user_id: user.id).includes(:organisation) }),

      # ── per organisation (inside organisations/<folder>/) ────────────────
      # Own structured data — exported in FULL:
      source(key: :time_sessions, model: 'TimeSession', tenant_scoped: true,
             attributes: %w[occurred_on duration description customer_description billed
                            billed_at invoice_number created_at updated_at],
             computed: { project_name: ->(r) { r.project&.name },
                         ticket_title: ->(r) { r.ticket&.title } },
             scope: ->(user) { TimeSession.where(creator_id: user.id).includes(:project, :ticket) }),
      source(key: :personal_tasks, model: 'PersonalTask', tenant_scoped: true,
             attributes: %w[title priority completed_at created_at updated_at],
             scope: ->(user) { PersonalTask.where(user: user) }),

      # Created content — INVENTORY only (Option A: no bodies, no blobs):
      source(key: :posts, model: 'Post', tenant_scoped: true,
             attributes: %w[is_private created_at updated_at],
             computed: { ticket_title: ->(r) { r.ticket&.title } },
             scope: ->(user) { Post.where(user_id: user.id).includes(:ticket) }),
      source(key: :post_reactions, model: 'PostReaction', tenant_scoped: true,
             attributes: %w[emoji created_at],
             computed: { ticket_title: ->(r) { r.post&.ticket&.title } },
             scope: ->(user) { PostReaction.where(user_id: user.id).includes(post: :ticket) }),
      source(key: :post_reads, model: 'PostRead', tenant_scoped: true,
             attributes: %w[read_at],
             computed: { ticket_title: ->(r) { r.post&.ticket&.title } },
             scope: ->(user) { PostRead.where(user_id: user.id).includes(post: :ticket) }),
      source(key: :created_tickets, model: 'Ticket', tenant_scoped: true,
             attributes: %w[title number ticket_type created_at updated_at],
             computed: { project_name: ->(r) { r.project&.name } },
             scope: ->(user) { Ticket.where(creator_id: user.id).includes(:project) }),
      # Meetings (Gespräche): INVENTORY only — title + date + project. Deliberately
      # NO notes/transcript bodies: those are third-party PII belonging to the org
      # (data controller), not the exporting user (plan §5 Slice 1a / D12).
      source(key: :created_meetings, model: 'Meeting', tenant_scoped: true,
             attributes: %w[title occurred_at],
             computed: { project_name: ->(r) { r.project&.name } },
             scope: ->(user) { Meeting.where(creator_id: user.id).includes(:project) }),
      # Meeting participations (Gespräche, Slice 1b): the user's OWN attendance
      # rows (user_id link). INVENTORY only — the participant name plus the
      # meeting's title/date/project, never notes/transcript bodies (those are
      # org-owned third-party PII, like created_meetings above).
      source(key: :meeting_participations, model: 'MeetingParticipant', tenant_scoped: true,
             attributes: %w[display_name created_at],
             computed: { meeting_title: ->(r) { r.meeting&.title },
                         meeting_date: ->(r) { r.meeting&.occurred_at },
                         project_name: ->(r) { r.meeting&.project&.name } },
             scope: ->(user) { MeetingParticipant.where(user_id: user.id).includes(meeting: :project) }),
      # Meeting analyses (Gespräche, Slice 7a): the user's OWN analyses. INVENTORY
      # only — the prompt title + date + meeting, never the analysis `content`
      # (org-owned third-party PII, like created_meetings above; plan §5 Slice 7a).
      source(key: :meeting_analyses, model: 'MeetingAnalysis', tenant_scoped: true,
             attributes: %w[prompt_title created_at],
             computed: { meeting_title: ->(r) { r.meeting&.title },
                         meeting_date: ->(r) { r.meeting&.occurred_at },
                         project_name: ->(r) { r.meeting&.project&.name } },
             scope: ->(user) { MeetingAnalysis.where(creator_id: user.id).includes(meeting: :project) }),
      # Via Ticket (tenant-scoped), NOT via TicketAssignment: the join table has
      # no tenant scope, so querying it inside with_tenant would return the
      # user's assignments across ALL orgs in every org folder.
      source(key: :assigned_tickets, model: 'Ticket', tenant_scoped: true,
             attributes: %w[title number ticket_type created_at],
             computed: { project_name: ->(r) { r.project&.name } },
             scope: lambda { |user|
               Ticket.joins(:ticket_assignments)
                     .where(ticket_assignments: { user_id: user.id })
                     .includes(:project).distinct
             }),
      source(key: :notes, model: 'Note', tenant_scoped: true,
             attributes: %w[title created_at updated_at],
             computed: { project_name: ->(r) { r.project&.name } },
             scope: ->(user) { Note.where(creator_id: user.id).includes(:project) }),
      source(key: :note_versions, model: 'NoteVersion', tenant_scoped: true,
             attributes: %w[created_at],
             computed: { note_title: ->(r) { r.note&.title } },
             scope: ->(user) { NoteVersion.where(author_id: user.id).includes(:note) }),
      source(key: :documents, model: 'Document', tenant_scoped: true,
             attributes: %w[created_at updated_at],
             computed: { project_name: ->(r) { r.project&.name } },
             scope: ->(user) { Document.where(creator_id: user.id).includes(:project) }),
      source(key: :document_versions, model: 'DocumentVersion', tenant_scoped: true,
             attributes: %w[document_id created_at],
             scope: ->(user) { DocumentVersion.where(user_id: user.id) }),
      source(key: :chatposts, model: 'Chatpost', tenant_scoped: true,
             attributes: %w[model_used created_at],
             computed: { chat_title: ->(r) { r.chat&.title } },
             scope: ->(user) { Chatpost.where(user_id: user.id).includes(:chat) }),
      # The thread FRAME, next to the posts above (assistant plan §5.1/§5.3). Scoped by
      # OWNER, not by "posted in it": a question of mine in somebody else's thread is
      # already covered by chatposts, and dragging their frame along would export a
      # thread that is not mine. The chat_title on a post is a convenience field, not
      # the thread's own record — without this source a person gets their questions
      # without the conversations they sit in.
      # projekt_chat_abbau: no `project_name` column and no `includes(:project)` any
      # more. A chat carries no project, so the value was nil on every row it would
      # still have produced -- and the association it read is gone, which would have
      # raised AssociationNotFound on the export of anyone who owns a chat.
      source(key: :chats, model: 'Chat', tenant_scoped: true,
             attributes: %w[title language created_at last_message_at],
             scope: ->(user) { Chat.where(user_id: user.id) }),
      source(key: :tags, model: 'Tag', tenant_scoped: true,
             attributes: %w[name created_at],
             scope: ->(user) { Tag.where(user_id: user.id) }),
      source(key: :smart_folders, model: 'SmartFolder', tenant_scoped: true,
             attributes: %w[name description target_object_type is_public created_at updated_at],
             scope: ->(user) { SmartFolder.where(user: user) }),
      source(key: :documentation_set_views, model: 'DocumentationSetView', tenant_scoped: true,
             attributes: %w[last_viewed_at],
             computed: { documentation_set_name: ->(r) { r.documentation_set&.name } },
             scope: ->(user) { DocumentationSetView.where(user: user).includes(:documentation_set) }),

      # Personal UI configuration per organisation:
      source(key: :dashboard_configurations, model: 'DashboardConfiguration', tenant_scoped: true,
             attributes: %w[layout created_at updated_at],
             computed: { project_name: ->(r) { r.project&.name } },
             scope: ->(user) { DashboardConfiguration.where(user_id: user.id).includes(:project) }),
      source(key: :overview_configurations, model: 'OverviewConfiguration', tenant_scoped: true,
             attributes: %w[layout created_at updated_at],
             scope: ->(user) { OverviewConfiguration.where(user_id: user.id) }),
      source(key: :view_configurations, model: 'ViewConfiguration', tenant_scoped: true,
             attributes: %w[view_type view_mode table_columns list_columns header_columns
                            detail_settings created_at updated_at],
             computed: { project_name: ->(r) { r.project&.name } },
             scope: ->(user) { ViewConfiguration.where(user_id: user.id).includes(:project) }),
      source(key: :view_states, model: 'ViewState', tenant_scoped: true,
             attributes: %w[key state viewable_type created_at],
             scope: ->(user) { ViewState.where(user_id: user.id) }),
      source(key: :chat_style_preferences, model: 'ChatStylePreference', tenant_scoped: true,
             attributes: %w[technicality length created_at],
             scope: ->(user) { ChatStylePreference.where(user: user) }),
      # The people directory row linked to the account (at most one per
      # organisation). creator_id/updater_id are authoring metadata on org
      # content (as analysis_prompts); unlinked rows are data about third
      # parties, whose requests go through the organisation as controller.
      source(key: :people, model: 'Person', tenant_scoped: true,
             attributes: %w[name salutation function department company email phone additional_details notes
                            created_at updated_at],
             scope: ->(user) { Person.where(user_id: user.id) }),
      # The heard forms of the glossary this account SPOKE (K4a): what speech
      # recognition heard from the person, for which term, in which project
      # and when. Data about the account, so it is exported. The speaker is
      # the account in two ways: as a member (user_id), or as the account's
      # own row of the people directory (person_id of a Person with this
      # user_id; :people exports that row, not the forms spoken as it). The
      # third reference is not exported: corrected_by_id is authoring metadata
      # on org knowledge (as analysis_prompts). A person_id of any other row is
      # a third party's, whose requests go through the organisation.
      source(key: :term_corrections, model: 'TermCorrection', tenant_scoped: true,
             attributes: %w[heard replaced_count created_at],
             computed: { term: ->(r) { r.glossary_term&.term }, project_name: ->(r) { r.project&.name } },
             scope: lambda { |user|
               TermCorrection.where(user_id: user.id)
                             .or(TermCorrection.where(person_id: Person.where(user_id: user.id).select(:id)))
                             .includes(:glossary_term, :project)
             }),
      source(key: :notification_subscriptions, model: 'NotificationSubscription', tenant_scoped: true,
             attributes: %w[subscribable_type source created_at],
             scope: ->(user) { NotificationSubscription.where(user: user) }),

      # Invitations — sent addresses are data the user provided themselves;
      # received ones matched by the CURRENT address (token NEVER exported):
      source(key: :invitations_sent, model: 'Invitation', tenant_scoped: true,
             attributes: %w[email sent_at accepted_at created_at],
             scope: ->(user) { Invitation.where(inviter_id: user.id) }),
      source(key: :invitations_received, model: 'Invitation', tenant_scoped: true,
             attributes: %w[sent_at accepted_at created_at],
             scope: ->(user) { Invitation.where(email: user.email) }),

      # E-mail delivery history — via notification join; recipient_email is a
      # legacy fallback only (the column is not populated on create):
      source(key: :email_history, model: 'EmailLog', tenant_scoped: true,
             serializer: 'UserDataExports::Serializers::EmailLogsSerializer')
    ].freeze

    # Tables with user references that are DELIBERATELY not part of the
    # personal export. Every entry needs a reason — the completeness guard
    # fails on unclassified tables. "Role model" = D9: org content belongs to
    # the organisation as data controller; it is served via the org export
    # (doc/org_data_export_plan.md), not the personal one.
    EXCLUDED = {
      'activities' => 'Org audit trail (role model); actor is a bare reference, PII-minimised by design',
      'notifications' => 'Transient delivery copies of org events; preferences + subscriptions ARE exported',
      'taggings' => 'Linkage metadata; the tags themselves are exported',
      'project_permissions' => 'Org-granted rights (role model; org export)',
      'time_session_permissions' => 'Org-granted rights (role model; org export)',
      'smart_folder_shares' => 'Third-party shares TO the user; the folder belongs to the sharer',
      'projects' => 'archived_by_id is editor metadata on an org object (role model)',
      'project_capabilities' => 'edited_by_user_id is editor metadata on org infrastructure',
      'project_layer4_visions' => 'edited_by_user_id is editor metadata on org infrastructure',
      'project_repositories' => 'connected_by_user_id is trigger metadata on org infrastructure',
      'documentation_sync_runs' => 'triggered_by_user_id is trigger metadata on org infrastructure',
      'project_index_runs' => 'triggered_by_user_id is trigger metadata on org infrastructure',
      'codebase_import_files' => 'Org import artifact (role model; retention topic, DSGVO audit P3)',
      'time_session_groups' => 'Org billing artifact; own sessions are in time_sessions.json',
      'meeting_participant_claim_rejections' => 'Org-scoped suppression marker ("this participant ' \
                                                'is not me"); only a normalized display name, ' \
                                                'recreatable UX state — no exportable content',
      'analysis_prompts' => 'Org-wide prompt library asset (Gespräche Slice 7a); creator_id is ' \
                            'authoring metadata on shared org infrastructure (role model, org export)',
      'glossary_terms' => 'Org-wide glossary (K4a, role model); created_by_id is authoring metadata on ' \
                          'shared org knowledge, like analysis_prompts. The heard forms a person spoke are ' \
                          'exported as term_corrections.json',
      'user_deletions' => 'Deletion audit log, metadata only by design; core state is in account.json',
      'user_data_exports' => 'The export mechanism itself; state is visible on the export page',
      'attachment_deletion_records' => 'Deletion proof owed to the CONTROLLER, not to the user ' \
                                       '(AVV § 12 Abs. 7); metadata by design, and user_id is set ' \
                                       'only on deleted export archives, whose state the export ' \
                                       'page already shows',
      'ticket_assignments' => 'Exported as assigned_tickets.json via the tenant-scoped Ticket join',
      'ticket_bulk_runs' => 'Org audit trail of a bulk edit (role model, like activities); user_id is a ' \
                            'bare reference to the runner, and the changes themselves live on the ' \
                            'tickets and in activities',
      'organisations' => 'ai_activated_by_id is trigger metadata on the org AI opt-in (role model)',
      'accounts' => 'owner_id is billing-relationship metadata on an Account (role model, ' \
                    'doc/billing_agentur_konto_plan.md D4); bundled organisations remain the ' \
                    'data controllers for their own content, not the personal export. ' \
                    'business_confirmed_by_id (B1/E8) is the SECOND person reference on this ' \
                    'table: it records who declared business status at checkout, a contractual ' \
                    'statement owed to the controller that is worthless without the person. ' \
                    'Named here because the guard only checks the table, so a new person ' \
                    'reference would otherwise inherit an old justification silently',
      'seat_events' => 'Billing record owed to the CONTROLLER and retained commercially ' \
                       '(doc/billing_agentur_konto_plan.md §17.2/§17.4): a bare (user, ' \
                       'organisation, date) reference with no content. user_id is kept on ' \
                       'purpose -- without it the per-account dedup rule (D4.1) stops being ' \
                       'verifiable -- while name and e-mail are deliberately NOT snapshotted, ' \
                       'so an evaluation shows "deleted user" and the invoice still adds up'
    }.freeze

    def self.global_sources
      SOURCES.reject(&:tenant_scoped)
    end

    def self.tenant_sources
      SOURCES.select(&:tenant_scoped)
    end

    def self.covered_tables
      SOURCES.map { |s| s.model.table_name }.uniq
    end
  end
end
