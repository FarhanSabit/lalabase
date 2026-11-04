# frozen_string_literal: true

Rails.application.routes.draw do
  # Health check: 200 once the app has booted, 500 if it raised on boot. The
  # Docker image's compose.yml waits on it; production.rb already exempts the
  # path from the host check and the https redirect.
  get 'up', to: 'rails/health#show', as: :rails_health_check

  namespace :admin do
    # Root route for /admin -> redirect to the dashboard
    root to: 'dashboard#index'

    get '/dashboard', to: 'dashboard#index', as: 'dashboard'
    resources :organisations, only: %i[index show update] do
      member do
        get :roles
        patch :toggle_code_indexing # operator flips whether repositories are indexed
        patch :toggle_assistant    # operator flips the per-org assistant (S3a, §13-2)
        patch :toggle_data_import  # operator flips the per-org CodebaseHQ import
      end
    end

    # The operator console (accounts, discounts, founder signups, price lists,
    # billing list, acquisition, founder-signup settings) draws its own routes
    # into this namespace from the engine gboyke/lalabase-operator, and only in
    # the internal process that loads it (doc/oss_core_split_plan.md 5.6, S3).
    # In this process they do not exist; spec/architecture/
    # admin_operator_boundary_guard_spec.rb keeps the core from naming them.

    # Deletion register (AVV § 12 Abs. 7, L3): information on request. Singular
    # for the same reason as above, there is exactly ONE register. No write
    # path: it is written at the deletion itself and maintained by two nightly
    # runs.
    resource :deletion_register, only: :show

    # System Settings Routes
    get 'system_settings', to: 'system_settings#index'
    patch 'system_settings/update_registration', to: 'system_settings#update_registration', as: 'update_registration'
    patch 'system_settings/update_deletion_settings', to: 'system_settings#update_deletion_settings', as: 'update_deletion_settings'
    patch 'system_settings/update_ai_quota', to: 'system_settings#update_ai_quota', as: 'update_ai_quota'
    patch 'system_settings/update_legal_identity', to: 'system_settings#update_legal_identity', as: 'update_legal_identity'

    # ==========================================================================
    # User Activities Routes
    # ==========================================================================
    # Provides comprehensive activity tracking and security monitoring
    #
    # Standard routes:
    # - GET /admin/user_activities           - List all activities with filtering
    # - GET /admin/user_activities/:id       - Show activity details
    #
    # Collection routes:
    # - GET /admin/user_activities/security  - Security-focused view
    # - POST /admin/user_activities/export   - Export as CSV
    #
    # Nested routes:
    # - GET /admin/users/:user_id/activities - Activities for specific user
    # ==========================================================================
    resources :user_activities, only: %i[index show] do
      collection do
        get :security, as: :security
        post :export
      end
    end

    # Add user activities as nested resource under users
    get 'users/:user_id/activities', to: 'user_activities#user_activities', as: :user_user_activities

    # ==========================================================================
    # Admin Users Management Routes
    # ==========================================================================
    # Provides administrative functionality for user management
    #
    # Standard RESTful routes:
    # - GET    /admin/users           (index)  - List all users with filtering
    # - GET    /admin/users/new       (new)    - Form to create user + organization
    # - GET    /admin/users/:id       (show)   - Display detailed user information
    # - POST   /admin/users           (create) - Create user + organization
    #
    # Custom member routes:
    # - PATCH  /admin/users/:id/toggle_active - Toggle user active/inactive status
    # ==========================================================================
    resources :users, only: %i[index show new create destroy] do
      collection do
        # List deleted users
        get :deleted
      end
      member do
        # Toggle user active/inactive status
        # Uses PATCH method for semantic correctness (partial update)
        # Includes CSRF protection and confirmation dialog in UI
        patch :toggle_active

        # Remove user from organization
        # DELETE /admin/users/:id/memberships/:membership_id
        delete 'memberships/:membership_id', to: 'users#destroy_membership', as: :membership
      end
    end
    resources :beusers do
      member do
        get 'edit_password'
        post 'update_password'
      end
    end

    # Email Logs Dashboard
    resources :email_logs, only: %i[index show] do
      member do
        post :resend
      end
      collection do
        get :stats
        get :export
      end
    end

    # System monitoring information
    get 'monitoring', to: 'monitoring#index'
    resources :ai_credentials do
      member do
        patch :activate
        patch :toggle_enabled
        post :test_connection
        post :vertex_availability
      end
      # Contract documents and assessed versions (doc/ki_vertragsdaten_plan.md).
      # Nested so that the credential_id comes from the route and never from the
      # request body, the same rule as for the account discounts.
      # update, because a document is the EVIDENCE, not the commitment: a
      # mistyped source reference or a wrong "gültig ab" must be correctable.
      # The immutability applies to the version next door.
      resources :documents, only: %i[create update destroy], controller: 'ai_credential_documents'
      resources :contracts, only: %i[create update], controller: 'ai_credential_contracts'
    end
    # Operator-curated AI offerings (KI-Pakete). Credentials are the stock room,
    # packages the shop window — hence the neighbouring menu entry. vertex_check
    # is POST because it probes: a GET must only ever read the probe cache.
    resources :ai_packages do
      member do
        post :vertex_check
      end
    end
    # Operator-curated global chat-persona pool (Prompt-Personas v2). No :show —
    # edit is the detail view, like roles/ai_credentials.
    resources :prompt_personas, except: :show
    post 'log_in' => 'sessions#create', :as => 'log_in'
    get 'log_in' => 'sessions#new' # , :as => 'log_in'
    get 'log_out' => 'sessions#destroy', :as => 'log_out'

    # Mission Control Jobs - authentication handled by bridge controller
    mount MissionControl::Jobs::Engine, at: 'jobs'
  end

  # The public pages -- landing, features, pricing, comparisons, FAQ, the legal
  # pages and their sitemap -- moved to gboyke/lalabase-website (website split,
  # W6). They are served there and reached through nginx; the core answers the
  # application and nothing else.
  #
  # An instance that hosts its own imprint has /legal/<page>
  # (LegalPagesController), and "/" belongs to the application (RootController).

  # `/docs` belongs to another program. The public documentation moved to
  # gboyke/lalabase-documentation (doc/docs_delivery_plan.md, D5) and nginx
  # routes that path to it, so this application answers nothing there. A route
  # here would not shadow it (nginx decides before Rails is asked), it would
  # simply be dead code that claims an address this application does not own. What
  # stayed is the READER of the catalogue that program writes
  # (Docs::Catalogue), which the in-app help under /hilfe uses.
  #
  # ⚠️ These were the ONLY routes in this application with a language in the
  # PATH, and the top rung of ApplicationController#request_locale read exactly
  # that. The rung went with them: no address could reach it any more. Whoever
  # adds a locale-prefixed route here reads that comment first.

  # The one-time link that signs in a visitor the separate website just signed
  # up (website split, step W2.4). Minted by the provisioning endpoint.
  get 'users/signup_handoff', to: 'users/signup_handoffs#show', as: :users_signup_handoff

  devise_for :users, controllers: {
    sessions: 'users/sessions',
    registrations: 'users/registrations',
    passwords: 'users/passwords',
    confirmations: 'users/confirmations',
    unlocks: 'users/unlocks'
  }

  # Self-service account deletion (outside organization scope)
  resource :account_deletion, only: %i[new create]

  # Cancel account deletion
  get 'cancel_account_deletion', to: 'cancel_account_deletions#show', as: :cancel_account_deletion
  post 'cancel_account_deletion', to: 'cancel_account_deletions#create'

  # Self-service GDPR data export (Art. 15/20, outside organization scope)
  resource :user_data_export, only: %i[show create] do
    get :download
  end

  # User preferences (outside organization scope for global settings)
  resource :user_preferences, only: %i[edit update] do
    member do
      get :general, action: :edit, defaults: { section: 'general' }
      get :display, action: :edit, defaults: { section: 'display' }
      get :tickets, action: :edit, defaults: { section: 'tickets' }
      get :meetings, action: :edit, defaults: { section: 'meetings' }
      get :datetime, action: :edit, defaults: { section: 'datetime' }
      get :language, action: :edit, defaults: { section: 'language' }
      get :session, action: :edit, defaults: { section: 'session' }
      # Backward-compatibility redirects for old show routes
      get :general_show, to: redirect('/user_preferences/general')
      get :datetime_show, to: redirect('/user_preferences/datetime')
      get :language_show, to: redirect('/user_preferences/language')
    end
  end

  # Cockpit (organisations#select) personalisation — user-global, outside org scope (the cockpit
  # runs without a tenant, like user_preferences).
  resource :cockpit_settings, only: [:update]

  # The billing area on the level it talks about (K2 of doc/konto_ebene_plan.md).
  # Outside the org scope on purpose: an Account bundles organisations, is not
  # tenant-scoped, and its owner needs no membership in any of them (N1).
  #
  # The PATH stays `billing` (E7): "konto" collides with account_deletion and with
  # Devise's vocabulary. The RESOURCE carries the `billing_` prefix so that no
  # global, ambiguous `account_path` helper comes into existence.
  resources :billing_accounts, path: 'billing', only: %i[index show edit update] do
    member { post :claim }
  end

  # In-app help (HELP surface of the docs engine, doc/in_app_hilfe_plan.md):
  # login-gated but deliberately OUTSIDE the org scope — the help must also work
  # from org-free pages (cockpit, user preferences) and for users without an org.
  # The controller picks up an optional org context from the session for the shell.
  # No locale in the path (slugs are language-stable, I18n.locale comes from the
  # user preference). Specific routes BEFORE the *slug catch-all (docs lesson).
  get 'hilfe', to: 'help#index', as: :help
  get 'hilfe/suche', to: 'help#search', as: :help_search
  get 'hilfe/*slug', to: 'help#show', as: :help_page

  # Client-side session liveness check + implicit Devise activity touch
  get 'session/touch', to: 'session_touch#show', as: :session_touch

  # Personal access tokens for API access (used by the MCP server, etc.)
  namespace :users do
    resources :personal_access_tokens, only: %i[index new create edit update destroy]
  end

  scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
    get 'mobile/projects', to: 'mobile_navigation#projects', as: :mobile_projects
    get 'mobile/more', to: 'mobile_navigation#more', as: :mobile_more
    # Authorized file proxy: serves ActiveStorage attachments only after a project-access
    # check (instead of via the unprotected, non-expiring default blob route).
    get 'files/:kind/:id', to: 'file_downloads#show', as: :file_download

    # CodebaseHQ Import Files
    resources :codebase_import_files, path: 'codebase_imports', only: %i[index new create show destroy] do
      member do
        get :preview_import
        post :execute_import
        get :select_project
        get :preview_tickets
        post :execute_tickets_import
        get :preview_time_sessions
        post :execute_time_sessions_import
        get :rollback
        delete :execute_rollback
        get 'assign_uploads/:project_id', to: 'codebase_import_files#assign_uploads', as: :assign_uploads
        post :execute_upload_assignment
      end
    end

    # Smart Folders as the main resource
    resources :smart_folders do
      collection do
        post :create_from_filters
      end
      member do
        patch :update_from_filters # Quick update of the rules from ad-hoc filters
        patch :rename # Name only, from the filter bar's tab menu (the full update assumes the whole form)
        patch :columns # The view's column list, from the filter bar's save row (doc/spaltenwahl_plan.md, S3)
        get :share # Shows the share form
        post :perform_share # Processes the share (new route)
        post :clone # Cloning the folder
        delete 'unshare/:user_id', to: 'smart_folders#unshare', as: :unshare_user # Revoke a single share
      end
    end

    # Helper routes for dynamic form content
    # Routes for dynamic form content without constraints
    get 'field_operators/:field', to: 'smart_folders#field_operators', as: 'field_operators'
    get 'reference_options/:field', to: 'smart_folders#reference_options', as: 'reference_options'

    # Appearance settings (sidebar color per user)
    resource :appearance, only: %i[show update], controller: 'appearances'

    # Sidebar pins (pinned projects/menu items per user)
    resource :sidebar_pins, only: [:update], controller: 'sidebar_pins'

    # Global search pin (persistent inline search bar toggle, per user + org)
    resource :search_pin, only: [:update], controller: 'search_pins'

    get 'power_search', to: 'power_search#index'
    post 'power_search', to: 'power_search#execute'

    # Organisation-wide TimeSession management
    resources :time_sessions, path: 'time-tracking' do
      collection do
        get 'tickets_for_project/:project_id', action: :tickets_for_project, as: :tickets_for_project
        post :bulk_assign_group
        # Two-column capture popover behind the hours sum in the ticket/meeting
        # header (?ticket_id= or ?meeting_id=, plus project_id).
        get :subject_popover
      end
    end

    # The ticket search of the "Link" modal: relations cross projects, so it searches every
    # ticket of the organisation the user may read (policy scope), not one project.
    resources :ticket_lookups, only: :index

    # Organisation-wide meetings index (Gespräche Slice 1c): "all conversations
    # with person X" across project boundaries, scoped to projects the user may
    # read in the :meetings area (policy scope, never without_tenant). Read-only
    # lookup tool — a click opens the meeting in its project's master-detail, so
    # there is no org-wide detail route. A dedicated slim controller, NOT the
    # project-nested MeetingsController (which is bound to @project).
    get 'meetings', to: 'meetings_overview#index', as: :meetings

    # The shared people directory of the organisation (Person): one page with a
    # lane, the list on the left, the person or the form in the lane. show, new
    # and edit answer the lane frame; a full visit lands on the index with
    # ?person_id= or ?new=person. A member without a row of their own opens
    # through members/:user_id (?member_id= on the page).
    resources :people do
      get 'members/:user_id', on: :collection, action: :member, as: :member
    end

    # The glossary of the organisation (K4a): one page with a lane, the shape
    # of the people directory. The terms on the left, a term or the form in the
    # lane; show, new and edit answer the lane frame, a full visit lands on the
    # index with ?term_id= or ?new=term. Confirm, reject, merge and deleting one
    # heard form (named by one of its corrections) are writes on a term.
    resources :glossary_terms, path: 'glossary', controller: 'glossary' do
      member do
        patch :confirm
        patch :reject
        post :merge
        delete 'heard/:correction_id', action: :destroy_heard_form, as: :heard_form
      end
    end

    # The column picker of "Alle Meetings" saves the overview's base view here:
    # the controller of the project route (view_configuration under a project),
    # without a project. The path default pins the list type; a view_type in the
    # query cannot override it.
    resource :meetings_view_configuration, controller: 'view_configurations', only: [], defaults: { view_type: 'meetings' } do
      patch :columns
      patch :apply_columns_to_all
    end

    # Teilnehmer-Claim (Nachtrag): org-level link/reject of external participations to
    # an org member. NOT project-nested — a claim spans every project the acting user
    # may write meetings in. Both are writes → POST; link goes through an actor,
    # reject is a trivial single create in the controller (seam rule).
    resources :meeting_participant_claims, only: [] do
      collection do
        post :link
        post :reject
      end
    end

    # TimeSessionGroups management
    resources :time_session_groups do
      member do
        # The bookings a billing already holds, for the assignment panel to show
        # on demand. Its own action rather than a slice of #show: the panel wants
        # a fragment, and loading a whole page into a turbo-frame to use ten lines
        # of it is a page render per expansion.
        get :entries
        get :chronological
        get :aggregated
        get :customer_export
        # The billing-status modal (D4): the form and the transition write. Same
        # path, two verbs; the write authorizes mark_as_billed? (stricter than
        # update? - the status is Admin/Finance business, decision Q3).
        get :billing_status
        patch :billing_status, action: :update_billing_status
        post :generate_customer_descriptions
        patch :update_customer_description
        get :export_customer_descriptions
      end
    end

    # resources :organisations

    resources :invitations, only: %i[new create destroy] do
      member do
        get :copy_link
        post :resend
      end
    end
    resource :accept_invitation, only: %i[show update] do
      get :success, on: :member
    end

    resources :memberships, only: %i[index edit update destroy]

    # Org-wide access matrix: read-only overview of who can access which project (admin-only)
    resources :access_matrix, only: %i[index]

    # User Activities for organization members
    resources :user_activities, only: [:index]

    # Notification system (URL path "inbox" — see doc/inbox_feature_spec.md)
    resources :notifications, path: 'inbox', only: %i[index show update destroy] do
      collection do
        # Bulk actions
        patch :mark_all_read
        patch :archive_all

        # Settings & preferences
        get :preferences
        patch :preferences, action: :update_preferences
        get :ticket_exceptions
        delete :remove_ticket_exception

        # Statistics & analytics (optional for later)
        get :stats
      end

      member do
        # Individual notification actions (for API consistency)
        patch :mark_read
        patch :mark_unread
        patch :archive
        patch :unarchive

        # Deep link that marks notification as read before redirecting
        get :open

        # Grouped notifications
        patch :mark_group_read
        get :activities
      end
    end

    # 301 redirects from the old /notifications path to /inbox.
    # Query strings are preserved manually (bookmarks like ?filter=unread).
    # See doc/inbox_feature_spec.md chapter 5.3.
    get 'notifications', to: redirect { |params, req|
      query = req.query_string.present? ? "?#{req.query_string}" : ''
      "/org/#{params[:organisation_id]}/inbox#{query}"
    }
    get 'notifications/*rest', to: redirect { |params, req|
      query = req.query_string.present? ? "?#{req.query_string}" : ''
      "/org/#{params[:organisation_id]}/inbox/#{params[:rest]}#{query}"
    }

    # Changelog / News
    get 'changelog', to: 'changelog#show', as: :changelog

    # Organisation Settings (name, domain, etc.)
    resource :settings, only: %i[show update], controller: 'organisation_settings'

    # "Archivierte Objekte" - the way back out of the archive. The projects index
    # is a redirect to the briefing and the sidebar hides archived projects, so
    # without this page the restore button on projects#edit is unreachable.
    #
    # Plural #index, not a singular #show: it IS a list. The base controller's
    # verify_policy_scoped is skipped in the controller with its reason, the way
    # PowerSearchController does it - the route shape follows the thing, not the
    # callback. Named "archives" (not "archived_projects") because the page is a
    # container: a second archivable type becomes one more section, not a rename.
    resources :archives, only: :index

    # The AI area's entry point (doc/ki_bereich_navigation_plan.md S2). The hub is the
    # single "KI" tab of the management bar; the three pages below keep their own routes
    # on purpose — renaming them would move 27 call sites and every redirect target the
    # package actions use, for URLs nobody outside the admin area ever sees.
    resource :ai_overview, only: [:show], path: 'ai', controller: 'ai_overviews'

    # "Verbrauch" — the AI area's consumption page (S6, L8). Its own route rather
    # than a section of #ai_settings: the quota bar, the six-month Nachweis and the
    # 30-day token statistic all sat on the settings page, which made the hub's
    # "Verbrauch" card point at the very same URL as its "Zugang" card.
    resource :ai_usage, only: [:show], controller: 'ai_usages'

    # The shortcut out of an organisation into its account's billing area
    # (K3 of doc/konto_ebene_plan.md). Both actions only FORWARD to
    # /billing/:id; the area itself lives outside the org scope, see there.
    #
    # Kept although it renders nothing: it is bookmarked, it is the target of the
    # "Rechnung" settings tab, and it carries the N2 deep-link work.
    #
    # `update` and `claim` are GONE on purpose. They were form targets, the forms
    # now post to the account paths, and a write route whose only job would be to
    # forward a body it cannot forward is a trap rather than a courtesy.
    resource :billing, only: %i[show edit], controller: 'billing'

    # "Eigene Konfiguration" — the setup screen behind the catalogue's own-configuration
    # card (doc/ki_bereich_navigation_plan.md S7, E6-A). Its own route because §3.4 asked
    # for one from the start: the card is the WAHL, this is the EINRICHTUNG, and squeezing
    # both onto #show is what produced the two-door page S7 takes apart.
    #
    # :destroy is "Zugang entfernen" (E2a), an action of its own on purpose — the save
    # never removes a key by omission, so removing one has to be asked for. The probe has
    # NO route: "Speichern und prüfen" is #update with a flag, because a second route
    # would be a second write path to the same columns.
    resource :ai_configuration, only: %i[show update destroy], controller: 'ai_configurations'

    # AI Settings for organisations
    #
    # ⚠️ No :update since S7. The BYOK form that posted here moved to
    # :ai_configuration above and its write became Actors::SaveAiConfiguration; leaving
    # the route in place would have kept the unprotected door open next to the guarded
    # one (E6-A: "danach gibt es EINE Tür").
    resource :ai_settings, only: %i[show] do
      member do
        post :test_connection
        # GDPR org-level AI opt-in (audit 2026-07-03): explicit activation /
        # deactivation by an org admin, recorded with timestamp + actor.
        post :activate
        post :deactivate
        # KI-Pakete P2 (doc/ki_pakete_plan.md §7): picking a curated package card
        # — and picking the "Eigene Konfiguration" card, which is the same write
        # with a blank id (E1-C). Deliberately NOT folded into #update: that
        # action owns the BYOK provider form, and a package choice is a different
        # write with its own protocol columns and its own Actor.
        post :select_package
        # KI-Pakete P4b (doc/ki_pakete_p4_plan.md §4): the consequence dialog that
        # has to precede a lane-moving switch — what changes legally, what the
        # re-embedding costs, whether the quota covers it. A GET of its own rather
        # than a panel on the settings page: E7 wants the estimate computed ONCE,
        # when the dialog opens, not on every render of #show.
        # A blank/absent ai_package_id means "back to Eigene Konfiguration", the
        # same convention #select_package uses (E1-C).
        get :confirm_package
      end
    end

    # AI Sync Status for organisations
    resource :ai_sync_status, only: [:show], controller: 'ai_sync_statuses' do
      member do
        post :reprocess_embeddings
      end
    end

    # The AI protocol (doc/ki_bereich_navigation_plan.md S5): who changed the AI
    # configuration, when, and from what to what. :show only, and that is the whole
    # design — the rows are written by the actions they record (P4e, S0) and are
    # evidence for the AVV, so there is no create, no update and above all no destroy
    # to route to.
    resource :ai_protocol, only: [:show], controller: 'ai_protocols'

    # In-app per-org chat-persona management (account_admin). Org rows override the
    # global pool in the picker via prefer_org_owned. No :show — edit is the detail.
    resources :prompt_personas, except: :show

    # Per-user chat answer-style level (ChatStylePreference). update sets ONE
    # dimension to an absolute level (the style pills under the chat composer).
    # Singular resource: exactly one row per (user, org). No destroy — resetting
    # is just picking the middle step, so it needs no separate action.
    resource :chat_style_preference, only: :update

    # Per-user standing persona choice (the assistant's settings menu, gear icon
    # in the panel header). Singular for the same reason as the style level above:
    # exactly one row per (user, org). No destroy -- clearing is submitting the
    # blank option, which means "the organisation's default".
    #
    # Its own resource rather than a second action on chat_style_preference: that
    # one's update is "set ONE dimension to a level" down to its parameter names,
    # and a persona is not a level. The row they share is a storage fact, not a
    # reason to overload one endpoint.
    resource :assistant_preference, only: :update, controller: 'assistant_preferences'

    # Per-user private "Notizblock" to-dos (PersonalTask). index renders the
    # slide-over drawer panel; create/update/destroy are quick-add, toggle/
    # priority and delete. Strictly owner-scoped (PersonalTaskPolicy).
    resources :personal_tasks, only: %i[index create update destroy]

    # S3a T2: org-wide personal assistant threads (project-less chats). These were
    # separate routes from the start because the removed surface's routes carried a
    # :project_id the org thread does not have (R-M7); since projekt_chat_abbau they
    # are the only chat routes there are. Lean controllers; ChatPolicy is the gate
    # (owner + the assistant pair from §13-2, no admin bypass).
    # update carries exactly one thing: the scope chip (S3a T5, §9.3).
    resource :assistant_analysis_prompts, only: %i[show create destroy]
    resources :assistant_ticket_suggestion_meetings, only: :index

    resources :assistant_chats, only: %i[show create destroy update] do
      resources :ticket_suggestion_runs, only: :show, controller: 'assistant_ticket_suggestion_runs' do
        post :accept, on: :member
        post :dismiss, on: :member
        post :retry, on: :member
      end
      resources :chatposts, only: %i[create destroy], controller: 'assistant_chatposts' do
        post :regenerate, on: :member
        resource :analysis, only: :create, controller: 'assistant_analyses'
      end
      # Bezugs-Sammlung S1 (§7.1): the reference collection of ONE thread, so it
      # hangs under that thread the way the chatposts do (parent param
      # :assistant_chat_id). The member segment is the composite key
      # "Ticket:<uuid>" -- the same value the POST body carries, the chip
      # publishes in data-reference-keys and the panel compares against.
      resources :references, only: %i[create destroy], controller: 'assistant_chat_references', param: :key
    end

    # S3a T4: the BODY of the companion panel (§7.7). The panel shell sits in the
    # application layout on every page; its content comes from here, and only once
    # somebody actually opens it. Singular resource on purpose: there is one panel,
    # and WHICH thread it shows is a query parameter, not a path segment.
    resource :assistant_panel, only: :show, controller: 'assistant_panels'

    # S3c T3: the ARTEFACT lane of the full view (§4, §8.1). Its own endpoint
    # rather than another state of the panel body, because the two lanes stand
    # side by side and each needs its own frame to be exchanged in. Which panel
    # kind and which record are query parameters -- the kind resolves through
    # Assistant::PanelRegistry, fail-closed, and the panel itself authorises the
    # rest (the address is user-typeable, §8.1).
    resource :assistant_artefact, only: :show, controller: 'assistant_artefacts'

    # S3c T2: the assistant's shareable address (§7.5, L3, and the jump target for
    # notifications). Its own short path rather than a member of the panel
    # resource above, because this is the one assistant address a HUMAN passes on
    # -- /assistant_panel/full reads like plumbing, and the panel endpoint is
    # plumbing, serving a turbo frame.
    #
    # It does NOT render the full view. That is a state of the permanent panel
    # node, and no page can render it: Turbo keeps the living element and throws
    # away whatever the server sent for it. So this sets the state the one way a
    # server can still reach that node, the address, and puts the user somewhere
    # real.
    get 'assistant', to: 'assistant_panels#full', as: :assistant

    # Add these routes outside the organisation_id scope

    resources :projects do
      member do
        patch :archive
        patch :unarchive
        post :create_default_attributes
        # Name + description form. The settings page (edit) is a pure hub of
        # navigation cards; this subpage carries the actual form.
        get :details
      end

      # Ticket Attribute Definitions (custom fields per project)
      resources :ticket_attribute_definitions, except: %i[show] do
        collection do
          patch :sort
        end
        member do
          patch :toggle_active
          get :merge_option
          patch :execute_merge
        end
      end

      # Allows /projects/:project_id/smart_folders and /projects/:project_id/smart_folders/new
      resources :smart_folders, only: %i[index new], controller: 'smart_folders'

      # Notification subscription routes
      resource :subscription, only: [], controller: 'notification_subscriptions' do
        post 'toggle'
      end

      # Project Activities
      resources :activities, only: [:index], module: :projects

      # Connected Git Repositories (M4 — project-aware chat)
      resources :project_repositories, only: %i[index new create destroy] do
        member do
          get :index_runs      # Indexing-run history of a repo
          post :reindex        # Manually trigger an incremental re-index
          patch :update_token  # Rotate the access token without disconnecting
        end
      end

      # View Configuration for table columns. No `edit`: the one-list modal it
      # served went with the legacy filter bar (07.09.2026); columns are chosen
      # in the picker panel now, which saves through :columns.
      resource :view_configuration, only: %i[update] do
        patch :update_view_mode
        patch :columns # the picker saves the base view's list here (doc/spaltenwahl_plan.md, S3)
        patch :apply_columns_to_all # the picker's "für alle Ansichten übernehmen" (doc/spaltenwahl_plan.md, S5)
      end

      # Dashboard Configuration
      resource :dashboard_configuration, only: %i[edit update] do
        delete :reset, on: :member
        post :widget_preview, on: :member
      end

      # Live in-widget refresh for the project dashboard (currently only the
      # recent_tickets widget's search). Mirrors the org-scoped overview_widgets.
      # GET /org/:id/projects/:project_id/dashboard_widgets/:key?q=…&display=…&period=…&limit=…
      resources :dashboard_widgets, only: :show, param: :key

      # The project's own times page is gone (doc/zeiten_eine_liste_plan.md): it
      # was the organisation list narrowed to one project. The address stays
      # alive, so an old link or bookmark lands on that list with the project
      # preselected and every other parameter kept. The nested write routes
      # (create, edit, update, destroy: the ticket and meeting modals) remain.
      get 'time_sessions', to: redirect { |path_params, request|
        query = Rack::Utils.parse_nested_query(request.query_string)
                           .merge('project_id_filter' => path_params[:project_id])
        list = Rails.application.routes.url_helpers.organisation_time_sessions_path(path_params[:organisation_id])
        "#{list}?#{query.to_query}"
      }
      resources :time_sessions, except: :index
      resources :project_permissions, only: %i[index create update destroy] do
        collection do
          get :info
          # "Take this person off the project", keyed by USER, not by permission:
          # a member who is on the project through a role right alone has no
          # permission row to address. Actors::RevokeProjectMember then picks the
          # mechanism (drop the grant, or block it). The extra path segment keeps
          # this apart from the DELETE on /project_permissions/:id.
          delete 'revoke/:user_id', action: :revoke, as: :revoke
        end
        member do
          get :time_sessions_settings
          patch :update_time_sessions_settings
        end
      end

      resources :tickets do
        # The bulk panel's shell for the lane (doc/ticket_bulk_edit_plan.md,
        # slice 3): the selection controller loads it into
        # turbo-frame#ticket_display_frame on the first tick.
        collection do
          get 'bulk_edit'
          # What the selected tickets hold today, per field (slice 4): the
          # panel fetches it after every change of the selection.
          # POST, not GET: a selection of a full page (200 ids) does not fit
          # into a request line (Puma caps it at 12 KB).
          post 'bulk_summary'
          # The run (slice 6), and its undo within the window (D8).
          patch 'bulk_update'
          patch 'bulk_runs/:id/undo', action: :undo_bulk_run, as: :undo_bulk_run
          # The other actions, each with its own confirmation (slice 7): what a
          # move or a delete takes with it, then the move, then the delete.
          post 'bulk_impact'
          post 'bulk_move'
          delete 'bulk_destroy'
        end

        member do
          post 'create_summary'
          get 'move_preflight'
          post 'move'
          patch 'update_kanban_attribute'
          get 'timeline'
        end

        # Inline quick-add of sub-tasks (the :ticket_id is the parent). Dedicated lean controller
        # so the fat tickets#create stays out of it; returns a focused Turbo Stream.
        resources :subtasks, only: %i[create], module: :tickets
        # Relations to other tickets of the organisation (the :ticket_id is the ticket shown):
        # new renders the "Link" modal, create and destroy answer with streams for this ticket.
        resources :relations, only: %i[new create destroy], module: :tickets
        # The ticket view, open for a moment, marks the viewer's notifications about it read.
        resource :notification_read, only: %i[update], module: :tickets
        # The meeting beside the ticket, read only: a frame request renders the panel, any other
        # request goes to the meeting's own page (doc/ticket_meeting_panel_plan.md, S1).
        resource :meeting_panel, only: %i[show], controller: 'ticket_meeting_panels'

        # Notification subscription routes
        resource :subscription, only: [], controller: 'notification_subscriptions' do
          post 'toggle'
          post 'subscribe_other'
          delete 'unsubscribe_other'
          get 'available_users'
        end

        resources :posts do
          resources :reactions, only: %i[create destroy], controller: 'post_reactions'
        end
      end
      resources :knowledge, only: [:index], controller: 'knowledge'
      # External documentation synced from the connected repo (read-only browsing).
      # :search returns the live Turbo-frame result list for the sidebar search
      # (mirrors the in-app help /hilfe/suche).
      resources :documentation, only: [:index], controller: 'documentation' do
        get :search, on: :collection
      end
      resources :documentation_sets, only: %i[new create edit update destroy], controller: 'documentation_sets' do
        member do
          post :sync
          # Logbook: git commits touching the set + sync run history (Slice 2).
          get :history
        end
      end
      # Wiki @-mention picker (Lexxy <lexxy-prompt src>): policy-scoped note/document search.
      resources :mentions, only: [:index], controller: 'mentions'
      # Meetings (Gespräche) — Slice 1a: project-scoped master-detail resource.
      resources :meetings do
        member do
          # AI summary (Slice 4): enqueues Meetings::SummaryJob; write-gated in the
          # controller (:meetings write). Async — the response shows "wird erstellt…".
          post :create_summary
          # One-click search & chat release flip (Meeting-Such-Status): flips
          # create_embeddings via Actors::SaveMeeting (job enqueue / PII purge).
          post :toggle_search
          # Moving into another project (doc/meeting_verschieben_plan.md): the
          # dialog (frame content) and the write, both behind move_meetings.
          get :move_preflight
          post :move
        end
        # Linking a participant to the people directory (S2b): new renders the dialog into
        # its frame (?q= searches), create links, destroy unlinks.
        resources :participants, only: [] do
          resource :link, only: %i[new create destroy], controller: 'meeting_participant_links'
        end
        collection do
          # LLM participant detection (Slice 5): runs BEFORE save on the raw
          # transcript payload (scoping via @project, no persisted meeting);
          # fail-closed ai_available? recheck + payload cap + per-user throttle.
          post :detect_participants
        end
        # Manual bidirectional ticket links (Slice 3). Nested under the meeting
        # because the link belongs to it; the :id on destroy is the Reference id.
        # Trivial writes (single create!/destroy) → controller, not an actor.
        resources :ticket_links, only: %i[create destroy], controller: 'meeting_ticket_links'
        # Legacy analysis creation remains deployment-compatible for already-open
        # forms and queued jobs; current creation lives in the assistant. update is
        # the publish/unpublish flip; destroy removes one. Visibility is per-creator.
        resources :analyses, only: %i[create update destroy], controller: 'meeting_analyses' do
          # Rolling-deploy fallback for an old page whose lazy lane has not loaded
          # yet. No creation form is rendered; the response points at the unified UI.
          get :lane, on: :collection
        end
        # Legacy prompt-library deletion for already-open analysis forms. Current
        # management uses assistant_analysis_prompts above; the prompt is org-wide.
        resources :analysis_prompts, only: %i[destroy], controller: 'analysis_prompts'
        # AI ticket suggestions (Slice 8, E22). run (collection) enqueues the async
        # generation for the whole meeting; accept/dismiss (member) act on one
        # suggestion — accept is a cross-area write (creates a real ticket). All in
        # one controller; :meetings write-gated (accept additionally :tickets write).
        resources :ticket_suggestions, only: [], controller: 'meeting_ticket_suggestions' do
          collection { post :run }
          member do
            post :accept
            post :dismiss
          end
        end
      end
      resources :notes do
        # Wiki version history + unified diff (read-only) for a note.
        resources :versions, only: %i[index show], controller: 'note_versions'
      end
      resources :documents do
        member do
          get :download
          post :create_version
          delete :destroy_version
          # "als aktuell setzen" (doc/dokumentansicht_plan.md, S2): moves
          # documents.current_version to ?version_id.
          patch :set_current_version
          # One version in the lane (doc/dateivorschau_plan.md, S1): ?version_id,
          # the frame road of the page state ?document_id=X&preview=V.
          get :preview
          get :download_plain_text
        end
      end
    end

    resources :roles do
      member do
        post :set_default
      end
    end

    resources :tags

    # Ticket Attribute Definitions are now nested under projects (see projects block above)

    # Today-Focus dashboard — "What is new since yesterday 6 AM"
    resource :briefing, only: :show, controller: 'briefings'

    # Single overview-widget refresh (Turbo frame): interactive period switch for the
    # personal week widgets (my_week_stats / my_week_chart). GET /org/:id/overview_widgets/:key?period=
    resources :overview_widgets, only: :show, param: :key

    # Per-user / per-org-default layout config for the organisation overview (briefings#show).
    # Org-scoped sibling of the project dashboard_configuration (mirrors its member routes).
    resource :overview_configuration, only: %i[edit update] do
      delete :reset, on: :member
      post :widget_preview, on: :member
    end

    # Personal dismissal of the onboarding banner above the overview widget grid
    # (Kettenglied 0 — doc/onboarding_plan.md D4).
    resource :onboarding_banner, only: :destroy

    # Organisation root: new briefing dashboard.
    # Old projects overview still reachable via /organisations/:id/projects.
    root 'briefings#show'

    mount ActionCable.server => '/cable'
  end

  # API Routes
  namespace :api do
    # Account creation for the separate website. Authenticated by one shared
    # secret and absent without it (website split, step W2.3).
    namespace :provisioning do
      namespace :v1 do
        resources :signups, only: :create, format: false
      end
    end

    # Public, read-only data consumed by the separate website. These endpoints
    # deliberately have no personal-access-token or Pundit layer.
    namespace :public do
      namespace :v1 do
        resource :price_list, only: :show, format: false
        resources :price_lists, only: :index, format: false
      end
    end

    resources :view_states, only: %i[show update]

    # MCP (Model Context Protocol) endpoint — stateless JSON-RPC, one request per
    # POST. Authenticated via Personal Access Token. Driven by the official `mcp`
    # SDK in Mcp::Dispatcher (see doc/mcp_server_plan.md).
    post 'mcp', to: 'mcp#handle'

    # API v1 — used by the MCP server and other external integrations.
    # Authenticated via Personal Access Token (Authorization: Bearer lalab_pat_...).
    namespace :v1 do
      resource :me, only: %i[show], controller: 'me'
      resources :notifications, only: %i[index] do
        member do
          post :mark_as_read
          post :archive
        end
        collection do
          post :mark_all_as_read
        end
      end
      resources :organisations, only: %i[index] do
        # People S3b: the people directory of one organisation, read only.
        resources :people, only: %i[index show]
        # A meeting, under the organisation because the project may be missing
        # (it then lands in the organisation's inbox project).
        resources :meetings, only: %i[create]
      end
      get 'time_sessions/open', to: 'time_sessions#open'
      resources :projects, only: %i[index] do
        resources :tickets, only: %i[index create]
        # REST R1: a ticket by the number users see. format: false and the
        # constraint keep "1.5" one segment: a malformed number (JSON 404), not
        # number 1 as format "5" nor a route miss.
        get 'tickets/number/:number', to: 'tickets#by_number', as: :ticket_by_number, format: false,
                                      constraints: { number: %r{[^/]+} }
        get :ticket_attribute_definitions, on: :member
        # REST R2: the project's notes and documents by title, read only.
        resources :knowledge, only: %i[index], controller: 'knowledge'
        # REST R8: the project's meetings, read only.
        resources :meetings, only: %i[index]
      end
      # REST R8: one meeting, read only, by its own id like a ticket.
      resources :meetings, only: %i[show]
      resources :tickets, only: %i[show update] do
        member do
          get :activities
          get :attachments
          # REST R3b: one change, by the rule of the MCP tool update_ticket.
          post :changes
        end
        resources :time_sessions, only: %i[index create]
        resources :posts, only: %i[create show]
      end
    end
  end

  # Organisation select/set/create (global, outside org scope)
  get 'select_organisation', to: 'organisations#select', as: :select_organisation
  post 'set_organisation', to: 'organisations#set', as: :set_organisation
  get  'new_organisation',    to: 'organisations#new',    as: :new_organisation
  post 'create_organisation', to: 'organisations#create', as: :create_organisation

  # ViewComponent previews (only in development)
  if Rails.env.development?
    mount ViewComponent::Engine => '/rails/view_components'

    # Style Guide
    get 'style-guide', to: 'style_guide#index'
    namespace :style_guide do
      get 'buttons'
      get 'forms'
      get 'colors'
      get 'themes'
      get 'typography'
      get 'headers'
      get 'modals'
      get 'drag_drop'
      get 'cards'
      get 'flash_messages'
      get 'tags'
      get 'activities'
      get 'empty_states'
      get 'name_display'
      get 'z_index'
      get 'changelog'
    end
  end

  # Email provider webhooks (public routes)
  namespace :webhooks do
    post 'email', to: 'email#webhook'
    post 'email/postmark', to: 'email#postmark'
    post 'email/sendgrid', to: 'email#sendgrid'
    post 'email/mailgun', to: 'email#mailgun'

    # GitHub push webhook — one URL per repo, disambiguated by the repo UUID
    # (no tenant context in a webhook). HMAC-verified in the controller.
    post 'repositories/:id', to: 'repositories#create', as: :repository
  end

  # The legal pages of THIS instance, when its operator wrote them here instead
  # of hosting them elsewhere (LegalPagesController). Deliberately under /legal
  # and not /impressum: the public marketing pages still own the German
  # addresses until W6, and this one has to outlive them.
  # instance_legal_page and not legal_page: while the public pages were still
  # here, LocalizedRoutesHelper defined legal_page_path for them and shadowed
  # this route. The helper is gone since W6, the name is kept -- it says whose
  # pages these are, and renaming a route costs every caller for nothing.
  get 'legal/:page', to: 'legal_pages#show', as: :instance_legal_page,
                     constraints: { page: Regexp.union(LegalIdentity::PAGES.map(&:to_s)) }

  # Notification unsubscribe (public routes)
  get 'unsubscribe/notifications', to: 'notification_unsubscribes#show', as: :unsubscribe_notifications
  patch 'unsubscribe/notifications', to: 'notification_unsubscribes#update'

  # "/" belongs to the application: signed in goes to work, everybody else to the
  # sign-in form. It used to redirect to /de, which on a self-hosted instance
  # showed our marketing page on somebody else's server (RootController).
  root to: 'root#show'
end
