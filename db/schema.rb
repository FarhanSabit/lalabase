# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_08_120300) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"
  enable_extension "uuid-ossp"
  enable_extension "vector"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "chatpost_role", ["system", "user", "assistant"]
  create_enum "notification_channel", ["in_app", "email"]
  create_enum "notification_event_type", ["ticket_commented", "ticket_assigned", "ticket_unassigned", "ticket_status_changed", "ticket_blocker", "project_announcement", "document_added", "mention", "system_message", "index_completed", "index_failed", "tickets_bulk_changed", "tickets_bulk_moved", "tickets_bulk_deleted"]
  create_enum "notification_frequency", ["immediate", "daily", "weekly", "never"]
  create_enum "notification_priority", ["low", "normal", "high", "critical"]
  create_enum "notification_state", ["queued", "sent", "delivered", "read", "archived"]
  create_enum "subscription_mode", ["follow", "mute", "immediate"]

  create_table "account_discounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.integer "percent_off", null: false
    t.date "starts_on", null: false
    t.date "ends_on"
    t.string "reason"
    t.string "granted_by_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "starts_on"], name: "index_account_discounts_on_account_id_and_starts_on"
  end

  create_table "accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "billing_email"
    t.uuid "owner_id"
    t.integer "guest_max_organisations", default: 1, null: false
    t.integer "guest_max_projects_per_organisation", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "billing_starts_on"
    t.string "billing_interval", default: "monthly", null: false
    t.integer "payment_terms_days", default: 14, null: false
    t.string "billing_name"
    t.string "billing_addressee"
    t.string "billing_street"
    t.string "billing_street_2"
    t.string "billing_postal_code"
    t.string "billing_city"
    t.string "billing_region"
    t.string "billing_country", limit: 2
    t.string "billing_email_cc"
    t.string "billing_reference"
    t.string "vat_id"
    t.string "vat_id_status", default: "unchecked", null: false
    t.datetime "vat_id_checked_at"
    t.string "vat_id_checked_name"
    t.datetime "business_confirmed_at"
    t.uuid "business_confirmed_by_id"
    t.string "business_confirmation_version"
    t.jsonb "acquisition"
    t.string "plan_key", default: "cloud", null: false
    t.index ["billing_starts_on"], name: "index_accounts_on_billing_starts_on"
    t.index ["business_confirmed_by_id"], name: "index_accounts_on_business_confirmed_by_id"
    t.index ["owner_id"], name: "index_accounts_on_owner_id"
  end

  create_table "action_text_rich_texts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.text "body"
    t.string "record_type", null: false
    t.uuid "record_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "to_tsvector('german'::regconfig, body)", name: "index_action_text_rich_texts_body_fts", where: "((record_type)::text = ANY (ARRAY[('Ticket'::character varying)::text, ('Post'::character varying)::text, ('Document'::character varying)::text]))", using: :gin
    t.index ["record_type", "record_id", "name"], name: "index_action_text_on_record_and_name"
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
    t.index ["record_type", "record_id", "name"], name: "index_action_texts_on_record_lookup"
  end

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.uuid "record_id", null: false
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_id", null: false
    t.uuid "organisation_id", null: false
    t.string "trackable_type", null: false
    t.uuid "trackable_id", null: false
    t.string "secondary_type"
    t.uuid "secondary_id"
    t.string "action", null: false
    t.string "key", null: false
    t.jsonb "parameters", default: {}
    t.jsonb "attribute_changes", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id", "created_at"], name: "index_activities_on_actor_and_time"
    t.index ["actor_id"], name: "index_activities_on_actor_id"
    t.index ["organisation_id", "action", "created_at"], name: "index_activities_on_org_action_and_time"
    t.index ["organisation_id", "key", "created_at"], name: "index_activities_on_org_key_and_time"
    t.index ["organisation_id"], name: "index_activities_on_organisation_id"
    t.index ["secondary_type", "secondary_id"], name: "index_activities_on_secondary"
    t.index ["secondary_type", "secondary_id"], name: "index_activities_on_secondary_ref"
    t.index ["trackable_type", "trackable_id", "created_at"], name: "index_activities_on_trackable_and_time"
    t.index ["trackable_type", "trackable_id"], name: "index_activities_on_trackable"
  end

  create_table "ai_credential_contract_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ai_credential_contract_id", null: false
    t.uuid "ai_credential_document_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_credential_contract_id", "ai_credential_document_id"], name: "idx_contract_documents_unique_pair", unique: true
    t.index ["ai_credential_document_id"], name: "idx_on_ai_credential_document_id_34b6d4b6af"
  end

  create_table "ai_credential_contracts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ai_credential_id", null: false
    t.string "training_usage", default: "unspecified", null: false
    t.string "retention_policy", default: "unspecified", null: false
    t.integer "retention_days"
    t.string "subprocessors_disclosure", default: "unspecified", null: false
    t.text "subprocessors"
    t.text "note"
    t.string "recorded_by_email"
    t.date "starts_on", null: false
    t.date "ends_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_credential_id", "starts_on"], name: "idx_credential_contracts_unique_start", unique: true
  end

  create_table "ai_credential_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ai_credential_id", null: false
    t.string "document_key", null: false
    t.string "title", null: false
    t.text "summary"
    t.string "url"
    t.string "locator"
    t.text "body"
    t.date "valid_from", null: false
    t.string "added_by_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_credential_id", "document_key", "valid_from"], name: "idx_credential_documents_unique_version", unique: true
  end

  create_table "ai_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "provider", default: "openai", null: false
    t.text "access_token", null: false
    t.string "organization_id"
    t.string "default_model"
    t.boolean "active", default: false
    t.boolean "enabled", default: true
    t.json "additional_config", default: {}
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "display_name"
    t.string "purpose", default: "both", null: false
    t.string "region"
    t.boolean "included_in_quota", default: false, null: false
    t.string "api_base"
    t.integer "input_cost_per_1m_cents"
    t.integer "output_cost_per_1m_cents"
    t.integer "embedding_cost_per_1m_cents"
    t.string "company_domicile"
    t.index ["active"], name: "index_ai_credentials_on_active"
    t.index ["enabled"], name: "index_ai_credentials_on_enabled"
    t.index ["provider", "active"], name: "index_ai_credentials_on_provider_and_active", unique: true, where: "(active = true)"
    t.index ["provider"], name: "index_ai_credentials_on_provider"
  end

  create_table "ai_package_tiers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ai_package_id", null: false
    t.string "key", null: false
    t.string "label", null: false
    t.uuid "chat_credential_id"
    t.string "chat_model"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_package_id", "key"], name: "idx_ai_package_tiers_unique_key_per_package", unique: true
    t.index ["chat_credential_id"], name: "index_ai_package_tiers_on_chat_credential_id"
  end

  create_table "ai_packages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "kind", default: "curated", null: false
    t.string "name", null: false
    t.text "description"
    t.string "jurisdiction"
    t.string "processing_region"
    t.text "provider_note"
    t.uuid "embedding_credential_id"
    t.string "embedding_model"
    t.integer "embedding_dims"
    t.boolean "active", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["embedding_credential_id"], name: "index_ai_packages_on_embedding_credential_id"
    t.index ["name"], name: "index_ai_packages_on_name", unique: true
  end

  create_table "ai_usage_rollups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "organisation_id", null: false
    t.string "organisation_name", null: false
    t.date "period_start", null: false
    t.bigint "credits_used", default: 0, null: false
    t.bigint "tokens_used", default: 0, null: false
    t.decimal "cost_cents", precision: 15, scale: 6, default: "0.0", null: false
    t.boolean "partial", default: false, null: false
    t.datetime "aggregated_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "period_start"], name: "idx_ai_usage_rollups_account_period"
    t.index ["organisation_id", "period_start"], name: "idx_ai_usage_rollups_unique_period", unique: true
  end

  create_table "ai_usages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "ai_credential_id"
    t.string "provider", null: false
    t.string "model_used"
    t.integer "tokens_used", default: 0
    t.decimal "cost_cents", precision: 12, scale: 6, default: "0.0"
    t.datetime "used_at", precision: nil
    t.json "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.string "subject_type"
    t.uuid "subject_id"
    t.string "action"
    t.integer "credits_used", default: 0, null: false
    t.index ["ai_credential_id"], name: "index_ai_usages_on_ai_credential_id"
    t.index ["organisation_id", "used_at"], name: "index_ai_usages_on_organisation_id_and_used_at"
    t.index ["organisation_id"], name: "index_ai_usages_on_organisation_id"
    t.index ["provider", "used_at"], name: "index_ai_usages_on_provider_and_used_at"
    t.index ["subject_type", "subject_id"], name: "index_ai_usages_on_subject_type_and_subject_id"
    t.index ["user_id"], name: "index_ai_usages_on_user_id"
  end

  create_table "analysis_prompts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "creator_id"
    t.string "title", null: false
    t.text "prompt_text", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_analysis_prompts_on_creator_id"
    t.index ["organisation_id"], name: "index_analysis_prompts_on_organisation_id"
  end

  create_table "attachment_deletion_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id"
    t.string "organisation_name"
    t.uuid "user_id"
    t.string "storage_key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.bigint "byte_size"
    t.string "record_type"
    t.datetime "deleted_at", null: false
    t.datetime "backup_deleted_at"
    t.date "backup_expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_attachment_deletion_records_on_deleted_at"
    t.index ["organisation_id", "deleted_at"], name: "idx_on_organisation_id_deleted_at_be48b83a3b"
    t.index ["storage_key"], name: "index_attachment_deletion_records_on_storage_key"
  end

  create_table "beusers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "firstname"
    t.string "lastname"
    t.string "email"
    t.string "password_digest"
    t.string "password_token"
    t.string "role", default: "user"
    t.boolean "active", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "chat_style_preferences", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "user_id", null: false
    t.integer "technicality", default: 2, null: false
    t.integer "length", default: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "prompt_persona_id"
    t.index ["organisation_id", "user_id"], name: "index_chat_style_preferences_on_organisation_id_and_user_id", unique: true
    t.index ["prompt_persona_id"], name: "index_chat_style_preferences_on_prompt_persona_id"
    t.index ["user_id"], name: "index_chat_style_preferences_on_user_id"
  end

  create_table "chatposts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "content"
    t.enum "role", default: "user", null: false, enum_type: "chatpost_role"
    t.uuid "user_id"
    t.uuid "chat_id", null: false
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "source_citations", default: [], null: false
    t.string "model_used"
    t.jsonb "token_usage", default: {}, null: false
    t.jsonb "tool_calls", default: [], null: false
    t.jsonb "source_coverage"
    t.jsonb "analysis_context"
    t.index ["chat_id"], name: "index_chatposts_on_chat_id"
    t.index ["organisation_id"], name: "index_chatposts_on_organisation_id"
  end

  create_table "chats", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id"
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "title"
    t.string "language"
    t.boolean "language_locked", default: true, null: false
    t.uuid "project_repository_id"
    t.datetime "last_message_at"
    t.uuid "prompt_persona_id"
    t.uuid "user_id"
    t.uuid "scope_project_id"
    t.uuid "scope_ticket_id"
    t.jsonb "scope_references", default: [], null: false
    t.index ["last_message_at"], name: "index_chats_on_last_message_at"
    t.index ["organisation_id"], name: "index_chats_on_organisation_id"
    t.index ["project_id"], name: "index_chats_on_project_id"
    t.index ["project_repository_id"], name: "index_chats_on_project_repository_id"
    t.index ["prompt_persona_id"], name: "index_chats_on_prompt_persona_id"
    t.index ["scope_project_id"], name: "index_chats_on_scope_project_id"
    t.index ["scope_ticket_id"], name: "index_chats_on_scope_ticket_id"
    t.index ["user_id"], name: "index_chats_on_user_id"
    t.check_constraint "jsonb_typeof(scope_references) = 'array'::text", name: "chats_scope_references_is_array"
    t.check_constraint "project_id IS NOT NULL OR user_id IS NOT NULL", name: "chats_org_thread_requires_user"
  end

  create_table "code_symbols", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_repository_id", null: false
    t.string "symbol_type", null: false
    t.string "name", null: false
    t.string "qualified_name", null: false
    t.string "file_path", null: false
    t.integer "start_line", null: false
    t.integer "end_line", null: false
    t.text "signature"
    t.string "language", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_code_symbols_on_organisation_id"
    t.index ["project_repository_id", "file_path"], name: "idx_code_symbols_repo_path"
    t.index ["project_repository_id", "qualified_name"], name: "idx_code_symbols_repo_qname"
    t.index ["project_repository_id"], name: "index_code_symbols_on_project_repository_id"
  end

  create_table "codebase_import_files", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "user_id", null: false
    t.string "file_type", null: false
    t.string "original_filename"
    t.text "file_content"
    t.integer "file_size"
    t.string "status", default: "uploaded"
    t.json "metadata", default: {}
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "processing_started_at"
    t.datetime "processing_completed_at"
    t.text "error_message"
    t.json "import_summary"
    t.uuid "project_id"
    t.index ["organisation_id", "file_type"], name: "index_codebase_import_files_on_organisation_id_and_file_type"
    t.index ["organisation_id", "project_id"], name: "index_codebase_import_files_on_organisation_id_and_project_id"
    t.index ["organisation_id"], name: "index_codebase_import_files_on_organisation_id"
    t.index ["project_id"], name: "index_codebase_import_files_on_project_id"
    t.index ["status"], name: "index_codebase_import_files_on_status"
    t.index ["user_id"], name: "index_codebase_import_files_on_user_id"
  end

  create_table "codebase_import_mappings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "codebase_id", null: false
    t.uuid "local_id", null: false
    t.string "entity_type", null: false
    t.json "mapping_data", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "organisation_id"
    t.index ["entity_type"], name: "index_codebase_import_mappings_on_entity_type"
    t.index ["local_id", "entity_type"], name: "index_codebase_import_mappings_on_local_id_and_entity_type"
    t.index ["organisation_id", "codebase_id", "entity_type"], name: "index_codebase_import_mappings_on_organisation_and_codebase_id", unique: true
  end

  create_table "codebase_uploads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "codebase_upload_id", null: false
    t.string "file_name", null: false
    t.string "linked_object_type", null: false
    t.string "linked_object_id", null: false
    t.string "file_path"
    t.boolean "processed", default: false
    t.uuid "organisation_id", null: false
    t.string "import_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["codebase_upload_id", "organisation_id"], name: "idx_on_codebase_upload_id_organisation_id_d46c273408"
    t.index ["import_session_id"], name: "index_codebase_uploads_on_import_session_id"
    t.index ["linked_object_type", "linked_object_id"], name: "idx_on_linked_object_type_linked_object_id_88d5bd8833"
    t.index ["organisation_id"], name: "index_codebase_uploads_on_organisation_id"
  end

  create_table "content_embeddings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.string "embeddable_type", null: false
    t.uuid "embeddable_id", null: false
    t.string "embedding_provider", null: false
    t.string "embedding_model", null: false
    t.integer "embedding_dims", null: false
    t.vector "embedding", null: false
    t.string "source_hash", null: false
    t.boolean "indexed", default: false, null: false
    t.datetime "embedded_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "((embedding)::halfvec(3072)) halfvec_cosine_ops", name: "idx_ce_code_symbol_3072_cos", where: "(((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 3072) AND indexed)", using: :hnsw
    t.index "((embedding)::halfvec(3072)) halfvec_l2_ops", name: "idx_ce_fragment_3072_l2", where: "(((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 3072) AND indexed)", using: :hnsw
    t.index "((embedding)::vector(1024)) vector_cosine_ops", name: "idx_ce_code_symbol_1024_cos", where: "(((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 1024) AND indexed)", using: :hnsw
    t.index "((embedding)::vector(1024)) vector_l2_ops", name: "idx_ce_fragment_1024_l2", where: "(((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 1024) AND indexed)", using: :hnsw
    t.index "((embedding)::vector(1536)) vector_cosine_ops", name: "idx_ce_code_symbol_1536_cos", where: "(((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 1536) AND indexed)", using: :hnsw
    t.index "((embedding)::vector(1536)) vector_l2_ops", name: "idx_ce_fragment_1536_l2", where: "(((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 1536) AND indexed)", using: :hnsw
    t.index "((embedding)::vector(768)) vector_cosine_ops", name: "idx_ce_code_symbol_768_cos", where: "(((embeddable_type)::text = 'CodeSymbol'::text) AND (embedding_dims = 768) AND indexed)", using: :hnsw
    t.index "((embedding)::vector(768)) vector_l2_ops", name: "idx_ce_fragment_768_l2", where: "(((embeddable_type)::text = 'Fragment'::text) AND (embedding_dims = 768) AND indexed)", using: :hnsw
    t.index ["embeddable_type", "embeddable_id", "embedding_provider", "embedding_model", "embedding_dims"], name: "idx_content_embeddings_unique_space", unique: true
    t.index ["organisation_id", "embeddable_type", "embedding_provider", "embedding_model", "embedding_dims"], name: "idx_content_embeddings_org_space"
    t.index ["organisation_id", "embedding_provider", "embedding_model", "embedding_dims"], name: "idx_content_embeddings_org_triple"
    t.check_constraint "vector_dims(embedding) = embedding_dims", name: "content_embeddings_dims_check"
  end

  create_table "dashboard_configurations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_id", null: false
    t.uuid "user_id"
    t.jsonb "layout", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_dashboard_configurations_on_organisation_id"
    t.index ["project_id"], name: "idx_dashboard_config_project_default", unique: true, where: "(user_id IS NULL)"
    t.index ["project_id"], name: "index_dashboard_configurations_on_project_id"
    t.index ["user_id", "project_id"], name: "idx_dashboard_config_user_project", unique: true
    t.index ["user_id"], name: "index_dashboard_configurations_on_user_id"
  end

  create_table "document_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "document_id", null: false
    t.uuid "organisation_id", null: false
    t.text "plain_text_version"
    t.integer "plain_text_word_count"
    t.boolean "create_embeddings", default: true
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.boolean "create_summary", default: false
    t.text "generated_summary", default: ""
    t.boolean "summary_creation_flag", default: false
    t.text "summary_creation_error", default: ""
    t.string "title"
    t.integer "number"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["document_id", "number"], name: "index_document_versions_on_document_id_and_number", unique: true
    t.index ["document_id"], name: "index_document_versions_on_document_id"
    t.index ["organisation_id"], name: "index_document_versions_on_organisation_id"
    t.index ["user_id"], name: "index_document_versions_on_user_id"
  end

  create_table "documentation_assets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "documentation_set_id", null: false
    t.string "path", null: false
    t.string "git_blob_sha", null: false
    t.string "content_type", null: false
    t.bigint "byte_size", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["documentation_set_id", "path"], name: "idx_documentation_assets_set_path", unique: true
    t.index ["organisation_id"], name: "index_documentation_assets_on_organisation_id"
  end

  create_table "documentation_commits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "documentation_set_id", null: false
    t.string "commit_sha", null: false
    t.string "author_name"
    t.string "message"
    t.datetime "committed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["documentation_set_id", "commit_sha"], name: "idx_documentation_commits_set_sha", unique: true
    t.index ["documentation_set_id", "committed_at"], name: "idx_documentation_commits_set_time"
    t.index ["documentation_set_id"], name: "index_documentation_commits_on_documentation_set_id"
    t.index ["organisation_id"], name: "index_documentation_commits_on_organisation_id"
  end

  create_table "documentation_pages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "documentation_set_id", null: false
    t.string "path", null: false
    t.string "title"
    t.text "markdown_body"
    t.text "rendered_html"
    t.string "git_blob_sha", null: false
    t.datetime "removed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.index ["documentation_set_id", "path"], name: "idx_documentation_pages_set_path", unique: true
    t.index ["documentation_set_id", "removed_at"], name: "idx_on_documentation_set_id_removed_at_c6f42b1828"
    t.index ["documentation_set_id"], name: "index_documentation_pages_on_documentation_set_id"
    t.index ["organisation_id"], name: "index_documentation_pages_on_organisation_id"
  end

  create_table "documentation_set_views", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "documentation_set_id", null: false
    t.uuid "user_id", null: false
    t.datetime "last_viewed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["documentation_set_id", "user_id"], name: "idx_doc_set_views_set_user", unique: true
    t.index ["documentation_set_id"], name: "index_documentation_set_views_on_documentation_set_id"
    t.index ["organisation_id"], name: "index_documentation_set_views_on_organisation_id"
    t.index ["user_id"], name: "index_documentation_set_views_on_user_id"
  end

  create_table "documentation_sets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_id", null: false
    t.uuid "project_repository_id", null: false
    t.string "name", null: false
    t.string "path_prefix", default: ".lalabase/doku/", null: false
    t.string "sync_status", default: "never_synced", null: false
    t.datetime "last_synced_at"
    t.string "last_synced_commit"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_documentation_sets_on_organisation_id"
    t.index ["project_id", "name", "organisation_id"], name: "idx_documentation_sets_project_name", unique: true
    t.index ["project_id"], name: "index_documentation_sets_on_project_id"
    t.index ["project_repository_id"], name: "index_documentation_sets_on_project_repository_id"
  end

  create_table "documentation_sync_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "documentation_set_id", null: false
    t.string "status", null: false
    t.string "trigger", null: false
    t.string "error_class"
    t.text "error_message"
    t.string "commit_sha"
    t.integer "pages_synced", default: 0, null: false
    t.integer "pages_removed", default: 0, null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.uuid "triggered_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "assets_synced", default: 0, null: false
    t.integer "assets_skipped", default: 0, null: false
    t.index ["documentation_set_id", "created_at"], name: "idx_on_documentation_set_id_created_at_714010eb45"
    t.index ["documentation_set_id"], name: "index_documentation_sync_runs_on_documentation_set_id"
    t.index ["organisation_id"], name: "index_documentation_sync_runs_on_organisation_id"
  end

  create_table "documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "current_version_id"
    t.uuid "creator_id", null: false
    t.index ["creator_id"], name: "index_documents_on_creator_id"
    t.index ["current_version_id"], name: "index_documents_on_current_version_id"
    t.index ["organisation_id"], name: "index_documents_on_organisation_id"
    t.index ["project_id"], name: "index_documents_on_project_id"
  end

  create_table "email_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "notification_id", null: false
    t.string "provider_message_id"
    t.integer "status", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "organisation_id", null: false
    t.binary "body_html_compressed"
    t.text "body_text"
    t.text "body_preview"
    t.string "recipient_email"
    t.string "subject"
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "opened_at"
    t.datetime "clicked_at"
    t.datetime "bounced_at"
    t.datetime "failed_at"
    t.integer "open_count", default: 0
    t.integer "click_count", default: 0
    t.integer "retry_count", default: 0
    t.string "bounce_type"
    t.text "failure_reason"
    t.uuid "resent_from_id"
    t.boolean "can_retry", default: true
    t.integer "lock_version", default: 0, null: false
    t.index ["notification_id", "status"], name: "index_email_logs_on_notification_id_and_status"
    t.index ["organisation_id", "sent_at"], name: "index_email_logs_on_organisation_id_and_sent_at"
    t.index ["organisation_id", "status", "created_at"], name: "idx_email_logs_dashboard"
    t.index ["organisation_id", "status"], name: "index_email_logs_on_organisation_id_and_status"
    t.index ["provider_message_id"], name: "idx_email_logs_provider_msg", where: "(provider_message_id IS NOT NULL)"
    t.index ["recipient_email"], name: "index_email_logs_on_recipient_email"
    t.index ["resent_from_id"], name: "index_email_logs_on_resent_from_id"
    t.index ["sent_at"], name: "index_email_logs_on_sent_at"
    t.index ["status", "created_at"], name: "index_email_logs_on_status_and_created_at"
  end

  create_table "embedding_spaces", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.string "embedding_provider", null: false
    t.string "embedding_model", null: false
    t.integer "embedding_dims", null: false
    t.string "api_base"
    t.text "access_token"
    t.string "organization_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "retired_at"
    t.uuid "ai_credential_id"
    t.index ["ai_credential_id"], name: "index_embedding_spaces_on_ai_credential_id"
    t.index ["organisation_id", "embedding_provider", "embedding_model", "embedding_dims"], name: "idx_embedding_spaces_unique_triple", unique: true
  end

  create_table "founder_signups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "company_name", null: false
    t.string "company_seat", null: false
    t.date "founded_on", null: false
    t.string "revenue_band", null: false
    t.string "phone"
    t.boolean "marketing_consent", default: false, null: false
    t.datetime "marketing_consent_at"
    t.string "status", default: "open", null: false
    t.datetime "decided_at"
    t.string "decided_by_email"
    t.text "previous_tools"
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_founder_signups_on_account_id", unique: true
    t.index ["status", "created_at"], name: "index_founder_signups_on_status_and_created_at"
  end

  create_table "fragments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "fragmentable_type", null: false
    t.uuid "fragmentable_id", null: false
    t.text "plain_text_content"
    t.string "version_token"
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fragmentable_type", "fragmentable_id"], name: "index_fragments_on_fragmentable"
    t.index ["organisation_id"], name: "index_fragments_on_organisation_id"
    t.index ["version_token"], name: "index_fragments_on_version_token"
  end

  create_table "glossary_extraction_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "started_by_id"
    t.string "job_id", null: false
    t.string "status", default: "queued", null: false
    t.jsonb "scope", default: {}, null: false
    t.jsonb "stats", default: {}, null: false
    t.string "error_code"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id"], name: "index_glossary_extraction_runs_on_job_id", unique: true
    t.index ["organisation_id"], name: "index_glossary_extraction_runs_on_organisation_id"
    t.index ["organisation_id"], name: "one_active_glossary_extraction_run", unique: true, where: "((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying])::text[]))"
    t.index ["started_by_id"], name: "index_glossary_extraction_runs_on_started_by_id"
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'running'::character varying, 'succeeded'::character varying, 'failed'::character varying]::text[])", name: "glossary_extraction_runs_status_known"
  end

  create_table "glossary_proposal_sources", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "glossary_proposal_id", null: false
    t.string "source_type", null: false
    t.uuid "source_id", null: false
    t.uuid "project_id"
    t.string "snippet", limit: 240, default: "", null: false
    t.integer "occurrences", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["glossary_proposal_id", "source_type", "source_id"], name: "index_glossary_proposal_sources_on_proposal_and_source", unique: true
    t.index ["organisation_id"], name: "index_glossary_proposal_sources_on_organisation_id"
    t.index ["project_id"], name: "index_glossary_proposal_sources_on_project_id"
    t.index ["source_type", "source_id"], name: "index_glossary_proposal_sources_on_source_type_and_source_id"
    t.check_constraint "occurrences >= 1", name: "glossary_proposal_sources_occurrences_positive"
    t.check_constraint "source_type::text = ANY (ARRAY['Ticket'::character varying, 'Post'::character varying, 'TicketDocument'::character varying, 'PostDocument'::character varying, 'Note'::character varying, 'DocumentVersion'::character varying]::text[])", name: "glossary_proposal_sources_source_type_known"
  end

  create_table "glossary_proposals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "glossary_extraction_run_id"
    t.string "term", limit: 255, null: false
    t.string "normalized_term", null: false
    t.string "category"
    t.jsonb "variants", default: [], null: false
    t.string "hint", limit: 160, default: "", null: false
    t.integer "occurrences", default: 0, null: false
    t.string "status", default: "open", null: false
    t.uuid "glossary_term_id"
    t.uuid "decided_by_id"
    t.datetime "decided_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decided_by_id"], name: "index_glossary_proposals_on_decided_by_id"
    t.index ["glossary_extraction_run_id"], name: "index_glossary_proposals_on_glossary_extraction_run_id"
    t.index ["glossary_term_id"], name: "index_glossary_proposals_on_glossary_term_id"
    t.index ["organisation_id", "normalized_term"], name: "index_glossary_proposals_on_org_and_normalized_term", unique: true
    t.index ["organisation_id", "status"], name: "index_glossary_proposals_on_organisation_id_and_status"
    t.check_constraint "\nCASE\n    WHEN jsonb_typeof(variants) = 'array'::text THEN jsonb_array_length(variants) <= 10 AND NOT jsonb_path_exists(variants, 'strict $[*]?(@.type() != \"string\")'::jsonpath)\n    ELSE false\nEND", name: "glossary_proposals_variants_shape"
    t.check_constraint "category IS NULL OR (category::text = ANY (ARRAY['person'::character varying, 'company'::character varying, 'product'::character varying, 'place'::character varying, 'domain'::character varying, 'foreign'::character varying]::text[]))", name: "glossary_proposals_category_known"
    t.check_constraint "occurrences >= 0", name: "glossary_proposals_occurrences_not_negative"
    t.check_constraint "status::text = ANY (ARRAY['open'::character varying, 'accepted'::character varying, 'dismissed'::character varying]::text[])", name: "glossary_proposals_status_known"
  end

  create_table "glossary_terms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.string "term", null: false
    t.string "normalized_term", null: false
    t.string "category"
    t.string "status", default: "confirmed", null: false
    t.uuid "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.index ["created_by_id"], name: "index_glossary_terms_on_created_by_id"
    t.index ["organisation_id", "normalized_term"], name: "index_glossary_terms_on_organisation_id_and_normalized_term", unique: true
  end

  create_table "imported_objects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.string "importable_type", null: false
    t.uuid "importable_id", null: false
    t.string "import_session_id", null: false
    t.string "import_source", null: false
    t.datetime "imported_at", null: false
    t.json "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["import_session_id", "import_source"], name: "index_imported_objects_on_import_session_id_and_import_source"
    t.index ["importable_type", "importable_id"], name: "index_imported_objects_on_importable"
    t.index ["imported_at"], name: "index_imported_objects_on_imported_at"
    t.index ["organisation_id", "import_session_id"], name: "idx_on_organisation_id_import_session_id_2f43c61367"
    t.index ["organisation_id"], name: "index_imported_objects_on_organisation_id"
  end

  create_table "invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email"
    t.string "token"
    t.uuid "organisation_id", null: false
    t.uuid "inviter_id", null: false
    t.datetime "sent_at"
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_invitations_on_organisation_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "mcp_idempotency_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "personal_access_token_id", null: false
    t.string "idempotency_key", null: false
    t.string "tool_name", null: false
    t.string "request_fingerprint", null: false
    t.text "response_content"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["personal_access_token_id", "idempotency_key"], name: "index_mcp_idempotency_keys_on_token_and_key", unique: true
  end

  create_table "meeting_analyses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "meeting_id", null: false
    t.uuid "creator_id"
    t.uuid "analysis_prompt_id"
    t.uuid "visible_to_user_id"
    t.string "prompt_title", null: false
    t.text "prompt_snapshot", null: false
    t.text "content", default: "", null: false
    t.boolean "is_private", default: true, null: false
    t.boolean "include_in_search", default: false, null: false
    t.boolean "creation_flag", default: false, null: false
    t.text "creation_error", default: "", null: false
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "source_context"
    t.string "source_answer_key"
    t.index ["analysis_prompt_id"], name: "index_meeting_analyses_on_analysis_prompt_id"
    t.index ["creator_id"], name: "index_meeting_analyses_on_creator_id"
    t.index ["is_private", "visible_to_user_id"], name: "index_meeting_analyses_on_is_private_and_visible_to_user_id"
    t.index ["meeting_id", "created_at"], name: "index_meeting_analyses_on_meeting_id_and_created_at"
    t.index ["organisation_id"], name: "index_meeting_analyses_on_organisation_id"
    t.index ["source_answer_key"], name: "index_meeting_analyses_on_source_answer_key", unique: true
  end

  create_table "meeting_participant_claim_rejections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "user_id", null: false
    t.string "normalized_name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id", "user_id", "normalized_name"], name: "idx_mp_claim_rejections_org_user_name", unique: true
    t.index ["user_id"], name: "index_meeting_participant_claim_rejections_on_user_id"
  end

  create_table "meeting_participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "meeting_id", null: false
    t.uuid "user_id"
    t.string "display_name", null: false
    t.string "normalized_name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "person_id"
    t.index ["meeting_id", "normalized_name"], name: "index_meeting_participants_on_meeting_id_and_normalized_name", unique: true
    t.index ["meeting_id", "user_id"], name: "index_meeting_participants_on_meeting_id_and_user_id", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["organisation_id", "normalized_name"], name: "idx_on_organisation_id_normalized_name_5eadc4a5e5"
    t.index ["person_id"], name: "index_meeting_participants_on_person_id"
    t.index ["user_id"], name: "index_meeting_participants_on_user_id"
    t.check_constraint "num_nonnulls(user_id, person_id) <= 1", name: "meeting_participants_one_key"
  end

  create_table "meeting_ticket_suggestion_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "meeting_id", null: false
    t.uuid "chatpost_id"
    t.uuid "project_id", null: false
    t.string "meeting_title", null: false
    t.string "project_title", null: false
    t.string "job_id", null: false
    t.string "status", default: "queued", null: false
    t.text "instruction", default: "", null: false
    t.jsonb "sources", default: {}, null: false
    t.jsonb "results", default: [], null: false
    t.boolean "result_truncated", default: false, null: false
    t.text "error", default: "", null: false
    t.datetime "retried_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chatpost_id"], name: "index_meeting_ticket_suggestion_runs_on_chatpost_id", unique: true
    t.index ["job_id"], name: "index_meeting_ticket_suggestion_runs_on_job_id", unique: true
    t.index ["meeting_id"], name: "index_meeting_ticket_suggestion_runs_on_meeting_id"
    t.index ["meeting_id"], name: "one_active_ticket_suggestion_run", unique: true, where: "((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying])::text[]))"
    t.index ["organisation_id"], name: "index_meeting_ticket_suggestion_runs_on_organisation_id"
  end

  create_table "meeting_ticket_suggestions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "meeting_id", null: false
    t.string "title", null: false
    t.text "description", default: "", null: false
    t.uuid "similar_ticket_id"
    t.uuid "created_ticket_id"
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "meeting_ticket_suggestion_run_id"
    t.index ["created_ticket_id"], name: "index_meeting_ticket_suggestions_on_created_ticket_id"
    t.index ["meeting_id", "status"], name: "index_meeting_ticket_suggestions_on_meeting_id_and_status"
    t.index ["meeting_ticket_suggestion_run_id"], name: "index_ticket_suggestions_on_run"
    t.index ["organisation_id"], name: "index_meeting_ticket_suggestions_on_organisation_id"
    t.index ["similar_ticket_id"], name: "index_meeting_ticket_suggestions_on_similar_ticket_id"
  end

  create_table "meetings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title", null: false
    t.datetime "occurred_at", null: false
    t.integer "duration_minutes"
    t.text "notes"
    t.text "transcript"
    t.text "plain_text_version"
    t.boolean "create_embeddings", default: false, null: false
    t.uuid "project_id", null: false
    t.uuid "organisation_id", null: false
    t.uuid "creator_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "generated_summary", default: "", null: false
    t.boolean "summary_creation_flag", default: false, null: false
    t.text "summary_creation_error", default: "", null: false
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.boolean "suggestions_creation_flag", default: false, null: false
    t.text "suggestions_creation_error", default: "", null: false
    t.index ["creator_id"], name: "index_meetings_on_creator_id"
    t.index ["organisation_id"], name: "index_meetings_on_organisation_id"
    t.index ["project_id", "occurred_at"], name: "index_meetings_on_project_id_and_occurred_at"
  end

  create_table "memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "organisation_id", null: false
    t.string "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "active", default: true, null: false
    t.uuid "role_id"
    t.index ["organisation_id"], name: "index_memberships_on_organisation_id"
    t.index ["role_id"], name: "index_memberships_on_role_id"
    t.index ["user_id", "organisation_id"], name: "index_memberships_on_user_id_and_organisation_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "note_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "note_id", null: false
    t.uuid "organisation_id", null: false
    t.text "html_body"
    t.text "markdown_body"
    t.string "content_hash", null: false
    t.uuid "author_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["note_id", "created_at"], name: "index_note_versions_on_note_id_and_created_at"
    t.index ["organisation_id"], name: "index_note_versions_on_organisation_id"
  end

  create_table "notes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title"
    t.text "description"
    t.uuid "project_id", null: false
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "create_embeddings", default: true
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.text "plain_text_version"
    t.integer "plain_text_word_count"
    t.uuid "creator_id", null: false
    t.text "markdown_body"
    t.integer "lock_version", default: 0, null: false
    t.index ["creator_id"], name: "index_notes_on_creator_id"
    t.index ["organisation_id"], name: "index_notes_on_organisation_id"
    t.index ["project_id"], name: "index_notes_on_project_id"
  end

  create_table "notification_preferences", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "organisation_id"
    t.string "scope_type"
    t.uuid "scope_id"
    t.enum "event_type", null: false, enum_type: "notification_event_type"
    t.enum "channel", default: "in_app", null: false, enum_type: "notification_channel"
    t.enum "frequency", default: "daily", null: false, enum_type: "notification_frequency"
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_notification_preferences_on_organisation_id"
    t.index ["user_id", "event_type", "channel"], name: "idx_pref_lookup"
    t.index ["user_id", "organisation_id", "scope_type", "scope_id", "event_type", "channel"], name: "idx_pref_uniqueness", unique: true
    t.index ["user_id"], name: "index_notification_preferences_on_user_id"
  end

  create_table "notification_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "organisation_id", null: false
    t.string "subscribable_type", null: false
    t.uuid "subscribable_id", null: false
    t.enum "mode", default: "follow", null: false, enum_type: "subscription_mode"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source"
    t.uuid "subscribed_by_id"
    t.index ["organisation_id"], name: "index_notification_subscriptions_on_organisation_id"
    t.index ["subscribable_type", "subscribable_id"], name: "idx_subscription_lookup"
    t.index ["subscribed_by_id"], name: "index_notification_subscriptions_on_subscribed_by_id"
    t.index ["user_id", "subscribable_type", "subscribable_id"], name: "idx_subscription_uniqueness", unique: true
    t.index ["user_id"], name: "index_notification_subscriptions_on_user_id"
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "recipient_id", null: false
    t.uuid "actor_id"
    t.string "notifiable_type", null: false
    t.uuid "notifiable_id", null: false
    t.enum "event_type", null: false, enum_type: "notification_event_type"
    t.enum "channel", default: "in_app", null: false, enum_type: "notification_channel"
    t.enum "priority", default: "normal", null: false, enum_type: "notification_priority"
    t.enum "state", default: "queued", null: false, enum_type: "notification_state"
    t.string "group_key", null: false
    t.integer "group_count", default: 1, null: false
    t.datetime "first_event_at", null: false
    t.datetime "last_event_at", null: false
    t.integer "score", default: 0, null: false
    t.string "dedupe_fingerprint", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "read_at"
    t.datetime "archived_at"
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "next_allowed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "project_id"
    t.index ["actor_id"], name: "index_notifications_on_actor_id"
    t.index ["event_type"], name: "index_notifications_on_event_type"
    t.index ["group_key"], name: "index_notifications_on_group_key"
    t.index ["notifiable_type", "notifiable_id"], name: "idx_notifications_notifiable"
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["organisation_id", "recipient_id", "state", "created_at"], name: "idx_notifications_tenant_recipient"
    t.index ["organisation_id"], name: "index_notifications_on_organisation_id"
    t.index ["payload"], name: "index_notifications_on_payload", using: :gin
    t.index ["project_id", "created_at"], name: "index_notifications_on_project_and_created_at"
    t.index ["project_id"], name: "index_notifications_on_project_id"
    t.index ["recipient_id", "channel", "dedupe_fingerprint"], name: "idx_unique_dedupe", unique: true
    t.index ["recipient_id", "last_event_at"], name: "index_notifications_on_recipient_and_last_event_at"
    t.index ["recipient_id", "project_id", "state"], name: "index_notifications_on_recipient_project_state"
    t.index ["recipient_id", "state", "created_at"], name: "idx_notifications_recipient_state"
    t.index ["recipient_id"], name: "index_notifications_on_recipient_id"
  end

  create_table "organisations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.string "subdomain"
    t.string "domain"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "ai_access_token"
    t.string "ai_organization_id"
    t.string "ai_provider", default: "openai"
    t.string "email_subject_prefix"
    t.string "notification_sender_email"
    t.string "preferred_chat_model"
    t.boolean "project_chat_enabled", default: false, null: false
    t.string "embedding_provider"
    t.string "embedding_model"
    t.string "embedding_api_base"
    t.text "embedding_access_token"
    t.string "embedding_organization_id"
    t.boolean "ai_enabled", default: false, null: false
    t.datetime "ai_activated_at"
    t.uuid "ai_activated_by_id"
    t.uuid "account_id"
    t.string "ai_api_base"
    t.integer "ai_quota_credits_override"
    t.integer "ai_quota_buffer_override"
    t.integer "embedding_dims"
    t.uuid "active_embedding_space_id"
    t.integer "embedding_retention_limit", default: 2, null: false
    t.uuid "ai_package_id"
    t.string "ai_package_tier_key"
    t.datetime "ai_package_selected_at"
    t.uuid "ai_package_selected_by_id"
    t.datetime "ai_connection_checked_at"
    t.string "ai_connection_status"
    t.boolean "data_import_enabled", default: false, null: false
    t.boolean "assistant_enabled", default: false, null: false
    t.boolean "code_indexing_enabled", default: false, null: false
    t.uuid "meeting_inbox_project_id"
    t.index ["account_id"], name: "index_organisations_on_account_id"
    t.index ["ai_activated_by_id"], name: "index_organisations_on_ai_activated_by_id"
    t.index ["ai_package_id"], name: "index_organisations_on_ai_package_id"
    t.index ["ai_provider"], name: "index_organisations_on_ai_provider"
    t.index ["meeting_inbox_project_id"], name: "index_organisations_on_meeting_inbox_project_id"
    t.index ["notification_sender_email"], name: "index_organisations_on_notification_sender_email"
  end

  create_table "outbox_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "activity_id", null: false
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "available_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "processed_at"
    t.integer "retry_count", default: 0
    t.string "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_id"], name: "index_outbox_events_on_activity_id"
    t.index ["available_at", "processed_at"], name: "idx_outbox_processing"
    t.index ["organisation_id"], name: "index_outbox_events_on_organisation_id"
  end

  create_table "overview_configurations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "user_id"
    t.jsonb "layout", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "idx_overview_config_org_default", unique: true, where: "(user_id IS NULL)"
    t.index ["organisation_id"], name: "index_overview_configurations_on_organisation_id"
    t.index ["user_id", "organisation_id"], name: "idx_overview_config_user_org", unique: true
    t.index ["user_id"], name: "index_overview_configurations_on_user_id"
  end

  create_table "people", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "user_id"
    t.string "name", null: false
    t.string "normalized_name", null: false
    t.string "function"
    t.string "department"
    t.string "company"
    t.string "email"
    t.string "phone"
    t.text "notes"
    t.uuid "creator_id"
    t.uuid "updater_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "salutation"
    t.jsonb "additional_details", default: [], null: false
    t.index ["organisation_id", "normalized_name"], name: "index_people_on_organisation_id_and_normalized_name"
    t.index ["organisation_id", "user_id"], name: "index_people_on_organisation_id_and_user_id", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["user_id"], name: "index_people_on_user_id"
    t.check_constraint "jsonb_typeof(additional_details) = 'array'::text AND jsonb_array_length(additional_details) <= 10", name: "people_additional_details_shape"
  end

  create_table "permissions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "role_id", null: false
    t.string "category", null: false
    t.string "action", null: false
    t.boolean "allowed", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["role_id", "category", "action"], name: "index_permissions_on_role_id_and_category_and_action", unique: true
  end

  create_table "personal_access_token_organisations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "personal_access_token_id", null: false
    t.uuid "organisation_id", null: false
    t.boolean "all_projects", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_personal_access_token_organisations_on_organisation_id"
    t.index ["personal_access_token_id", "organisation_id"], name: "idx_pat_orgs_uniq", unique: true
  end

  create_table "personal_access_token_projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "personal_access_token_id", null: false
    t.uuid "project_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["personal_access_token_id", "project_id"], name: "idx_pat_projects_uniq", unique: true
    t.index ["project_id"], name: "index_personal_access_token_projects_on_project_id"
  end

  create_table "personal_access_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "name", null: false
    t.string "token_hash", null: false
    t.string "token_prefix", limit: 12, null: false
    t.datetime "last_used_at"
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "read_only", default: true, null: false
    t.boolean "all_organisations", default: false, null: false
    t.index ["token_hash"], name: "index_personal_access_tokens_on_token_hash", unique: true
    t.index ["user_id", "created_at"], name: "index_personal_access_tokens_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_personal_access_tokens_on_user_id"
  end

  create_table "personal_tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "user_id", null: false
    t.string "title", null: false
    t.integer "priority"
    t.integer "position", default: 0, null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id", "user_id", "completed_at"], name: "index_personal_tasks_on_org_user_completed"
    t.index ["user_id"], name: "index_personal_tasks_on_user_id"
  end

  create_table "post_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "post_id", null: false
    t.uuid "organisation_id", null: false
    t.text "plain_text_version"
    t.integer "plain_text_word_count"
    t.boolean "create_embeddings", default: true
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_post_documents_on_organisation_id"
  end

  create_table "post_reactions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "post_id", null: false
    t.uuid "user_id", null: false
    t.string "emoji", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_post_reactions_on_organisation_id"
    t.index ["post_id", "user_id", "emoji"], name: "index_post_reactions_on_post_user_emoji", unique: true
    t.index ["post_id"], name: "index_post_reactions_on_post_id"
    t.index ["user_id"], name: "index_post_reactions_on_user_id"
  end

  create_table "post_reads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "post_id", null: false
    t.uuid "user_id", null: false
    t.datetime "read_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_post_reads_on_organisation_id"
    t.index ["post_id", "user_id"], name: "index_post_reads_on_post_user", unique: true
    t.index ["post_id"], name: "index_post_reads_on_post_id"
    t.index ["user_id"], name: "index_post_reads_on_user_id"
  end

  create_table "posts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ticket_id", null: false
    t.uuid "user_id"
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "create_embeddings", default: true
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.text "plain_text_version"
    t.integer "plain_text_word_count"
    t.boolean "is_private", default: false, null: false
    t.uuid "visible_to_user_id"
    t.index ["is_private", "visible_to_user_id"], name: "index_posts_on_privacy"
    t.index ["organisation_id"], name: "index_posts_on_organisation_id"
    t.index ["ticket_id", "created_at"], name: "index_posts_on_ticket_created", comment: "For loading ticket timeline chronologically"
    t.index ["ticket_id", "is_private", "created_at"], name: "index_posts_on_ticket_privacy_created", comment: "For timeline with privacy filtering"
    t.index ["ticket_id", "is_private"], name: "index_posts_on_ticket_and_privacy"
    t.index ["user_id", "created_at"], name: "index_posts_on_user_created", comment: "For user activity views"
    t.index ["user_id"], name: "index_posts_on_user_id", comment: "Foreign key index for post users"
    t.index ["visible_to_user_id"], name: "index_posts_on_visible_to_user_id"
  end

  create_table "price_lists", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "plan_key", null: false
    t.string "currency", default: "EUR", null: false
    t.date "starts_on", null: false
    t.date "ends_on"
    t.string "note"
    t.string "created_by_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["plan_key", "starts_on"], name: "index_price_lists_on_plan_key_and_starts_on"
  end

  create_table "price_tiers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "price_list_id", null: false
    t.string "billing_interval", null: false
    t.integer "min_seats", null: false
    t.integer "max_seats"
    t.integer "base_amount_cents", default: 0, null: false
    t.integer "per_seat_amount_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["price_list_id", "billing_interval", "min_seats"], name: "idx_price_tiers_unique_rung_per_list", unique: true
  end

  create_table "product_knowledge_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "source", null: false
    t.string "locale", null: false
    t.string "slug", null: false
    t.string "title", null: false
    t.string "section"
    t.text "description"
    t.text "body_markdown", null: false
    t.text "body_text", null: false
    t.string "content_hash", null: false
    t.date "published_on"
    t.virtual "search_vector", type: :tsvector, as: "\nCASE locale\n    WHEN 'de'::text THEN ((setweight(to_tsvector('german'::regconfig, (COALESCE(title, ''::character varying))::text), 'A'::\"char\") || setweight(to_tsvector('german'::regconfig, COALESCE(description, ''::text)), 'B'::\"char\")) || setweight(to_tsvector('german'::regconfig, COALESCE(body_text, ''::text)), 'C'::\"char\"))\n    WHEN 'en'::text THEN ((setweight(to_tsvector('english'::regconfig, (COALESCE(title, ''::character varying))::text), 'A'::\"char\") || setweight(to_tsvector('english'::regconfig, COALESCE(description, ''::text)), 'B'::\"char\")) || setweight(to_tsvector('english'::regconfig, COALESCE(body_text, ''::text)), 'C'::\"char\"))\n    ELSE NULL::tsvector\nEND", stored: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["search_vector"], name: "index_product_knowledge_entries_on_search_vector", using: :gin
    t.index ["source", "locale", "slug"], name: "index_product_knowledge_entries_on_source_locale_slug", unique: true
    t.check_constraint "locale::text = ANY (ARRAY['de'::character varying, 'en'::character varying]::text[])", name: "product_knowledge_entries_locale_check"
  end

  create_table "project_capabilities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_id", null: false
    t.string "name", null: false
    t.text "description", null: false
    t.jsonb "key_modules", default: [], null: false
    t.boolean "auto_generated", default: true, null: false
    t.uuid "edited_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["edited_by_user_id"], name: "index_project_capabilities_on_edited_by_user_id"
    t.index ["organisation_id"], name: "index_project_capabilities_on_organisation_id"
    t.index ["project_id", "name"], name: "index_project_capabilities_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_project_capabilities_on_project_id"
  end

  create_table "project_index_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_repository_id", null: false
    t.uuid "triggered_by_user_id"
    t.string "trigger", null: false
    t.string "status", null: false
    t.boolean "incremental", default: false, null: false
    t.datetime "started_at", null: false
    t.datetime "finished_at", null: false
    t.string "commit_sha"
    t.integer "files_count", default: 0, null: false
    t.integer "symbols_added", default: 0, null: false
    t.integer "symbols_removed", default: 0, null: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_project_index_runs_on_organisation_id"
    t.index ["project_repository_id", "created_at"], name: "idx_on_project_repository_id_created_at_faef1120bf"
    t.index ["triggered_by_user_id"], name: "index_project_index_runs_on_triggered_by_user_id"
  end

  create_table "project_indexes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_repository_id", null: false
    t.string "status", default: "pending", null: false
    t.string "layer_4_status", default: "pending", null: false
    t.string "layer_3_status", default: "pending", null: false
    t.string "layer_1_status", default: "pending", null: false
    t.integer "layer_1_files_total", default: 0, null: false
    t.integer "layer_1_files_done", default: 0, null: false
    t.string "last_indexed_commit"
    t.datetime "last_indexed_at"
    t.text "error_message"
    t.integer "index_version", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_project_indexes_on_organisation_id"
    t.index ["project_repository_id"], name: "index_project_indexes_on_project_repository_id", unique: true
  end

  create_table "project_layer4_visions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_id", null: false
    t.text "content", null: false
    t.boolean "auto_generated", default: true, null: false
    t.uuid "edited_by_user_id"
    t.string "language", default: "en", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["edited_by_user_id"], name: "index_project_layer4_visions_on_edited_by_user_id"
    t.index ["organisation_id"], name: "index_project_layer4_visions_on_organisation_id"
    t.index ["project_id"], name: "index_project_layer4_visions_on_project_id", unique: true
  end

  create_table "project_permissions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.uuid "user_id", null: false
    t.integer "tickets_access", default: 0, null: false
    t.integer "notes_access", default: 0, null: false
    t.integer "chats_access", default: 0, null: false
    t.integer "documents_access", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at"
    t.integer "members_access", default: 0, null: false
    t.datetime "last_accessed_at"
    t.integer "documentation_access", default: 0, null: false
    t.integer "meetings_access", default: 0, null: false
    t.index ["deleted_at"], name: "index_project_permissions_on_deleted_at"
    t.index ["user_id", "last_accessed_at"], name: "index_project_permissions_on_user_last_accessed"
    t.index ["user_id", "project_id"], name: "index_project_permissions_on_user_id_and_project_id", unique: true
  end

  create_table "project_repositories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_id", null: false
    t.string "provider", null: false
    t.string "provider_repo_id", null: false
    t.string "full_name", null: false
    t.string "default_branch", null: false
    t.text "access_token", null: false
    t.uuid "connected_by_user_id"
    t.datetime "connected_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "webhook_secret"
    t.index ["connected_by_user_id"], name: "index_project_repositories_on_connected_by_user_id"
    t.index ["organisation_id"], name: "index_project_repositories_on_organisation_id"
    t.index ["project_id"], name: "index_project_repositories_on_project_id"
    t.index ["provider", "provider_repo_id", "organisation_id"], name: "idx_project_repositories_provider_repo_uniq", unique: true
  end

  create_table "projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.text "repository"
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "archived_at"
    t.uuid "archived_by_id"
    t.string "system_kind"
    t.index ["archived_at"], name: "index_projects_on_archived_at"
    t.index ["organisation_id", "system_kind"], name: "idx_projects_on_org_and_system_kind", unique: true, where: "(system_kind IS NOT NULL)"
    t.index ["organisation_id"], name: "index_projects_on_organisation_id"
  end

  create_table "prompt_personas", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id"
    t.string "key", null: false
    t.jsonb "labels", default: {}, null: false
    t.jsonb "prompt_fragments", default: {}, null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.boolean "system", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_prompt_personas_on_global_key", unique: true, where: "(organisation_id IS NULL)"
    t.index ["organisation_id", "key"], name: "index_prompt_personas_on_org_and_key", unique: true, where: "(organisation_id IS NOT NULL)"
  end

  create_table "references", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.string "source_type", null: false
    t.uuid "source_id", null: false
    t.string "target_type", null: false
    t.uuid "target_id", null: false
    t.string "target_title_snapshot"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_references_on_organisation_id"
    t.index ["source_type", "source_id", "target_type", "target_id"], name: "index_references_unique_source_target", unique: true
    t.index ["target_type", "target_id", "organisation_id"], name: "index_references_on_target_and_org"
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title", null: false
    t.text "description"
    t.boolean "is_default", default: false
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "billable", default: true, null: false
    t.index ["organisation_id", "title"], name: "index_roles_on_organisation_id_and_title", unique: true
  end

  create_table "seat_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "organisation_id", null: false
    t.string "organisation_name", null: false
    t.uuid "user_id", null: false
    t.uuid "role_id"
    t.string "event", null: false
    t.datetime "occurred_at", null: false
    t.boolean "billable", null: false
    t.boolean "counted", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "occurred_at"], name: "idx_seat_events_account_occurred"
    t.index ["organisation_id", "user_id", "occurred_at"], name: "idx_seat_events_membership_timeline"
  end

  create_table "seat_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.date "period_start", null: false
    t.string "status", null: false
    t.integer "seat_count"
    t.jsonb "pairs", default: [], null: false
    t.string "error"
    t.datetime "computed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "period_start"], name: "idx_seat_snapshots_unique_period", unique: true
    t.index ["period_start"], name: "index_seat_snapshots_on_period_start"
  end

  create_table "smart_folder_rule_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "smart_folder_id", null: false
    t.string "name"
    t.integer "position", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["smart_folder_id", "position"], name: "index_smart_folder_rule_groups_on_smart_folder_id_and_position"
    t.index ["smart_folder_id"], name: "index_smart_folder_rule_groups_on_smart_folder_id"
  end

  create_table "smart_folder_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "smart_folder_rule_group_id", null: false
    t.string "field", null: false
    t.string "operator", null: false
    t.text "value"
    t.text "display_value"
    t.integer "position", default: 1, null: false
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["config"], name: "index_smart_folder_rules_on_config", using: :gin
    t.index ["field", "operator"], name: "index_smart_folder_rules_on_field_and_operator"
    t.index ["smart_folder_rule_group_id", "position"], name: "idx_on_smart_folder_rule_group_id_position_5c8bc7ff32"
    t.index ["smart_folder_rule_group_id"], name: "index_smart_folder_rules_on_smart_folder_rule_group_id"
  end

  create_table "smart_folder_shares", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "smart_folder_id", null: false
    t.uuid "user_id", null: false
    t.boolean "can_edit", default: false
    t.boolean "can_share", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["smart_folder_id", "user_id"], name: "index_smart_folder_shares_on_smart_folder_id_and_user_id", unique: true
    t.index ["smart_folder_id"], name: "index_smart_folder_shares_on_smart_folder_id"
    t.index ["user_id"], name: "index_smart_folder_shares_on_user_id"
  end

  create_table "smart_folders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.uuid "user_id", null: false
    t.uuid "project_id"
    t.uuid "organisation_id", null: false
    t.integer "sort_by", default: 0
    t.integer "color_code"
    t.integer "position"
    t.text "description"
    t.boolean "is_public", default: false
    t.integer "public_access_level", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "target_object_type", default: "Note"
    t.jsonb "display_columns"
    t.string "sort_column"
    t.string "sort_direction"
    t.index ["organisation_id", "is_public"], name: "index_smart_folders_on_organisation_id_and_is_public"
    t.index ["organisation_id", "project_id"], name: "index_smart_folders_on_organisation_id_and_project_id"
    t.index ["organisation_id", "target_object_type"], name: "index_smart_folders_on_organisation_id_and_target_object_type"
    t.index ["organisation_id", "user_id"], name: "index_smart_folders_on_organisation_id_and_user_id"
    t.index ["organisation_id"], name: "index_smart_folders_on_organisation_id"
    t.index ["project_id"], name: "index_smart_folders_on_project_id"
    t.index ["user_id"], name: "index_smart_folders_on_user_id"
  end

  create_table "solid_queue_blocked_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "job_id", null: false
    t.uuid "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.uuid "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "system_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.text "value"
    t.string "data_type", default: "string"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_system_settings_on_key", unique: true
  end

  create_table "taggings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tag_id", null: false
    t.string "taggable_type", null: false
    t.uuid "taggable_id", null: false
    t.uuid "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tag_id", "taggable_type", "taggable_id"], name: "index_taggings_uniqueness", unique: true
    t.index ["tag_id", "taggable_type"], name: "index_taggings_on_tag_and_type", comment: "For finding objects with specific tags"
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_type", "taggable_id", "tag_id"], name: "index_taggings_on_taggable_and_tag", comment: "For loading tags for specific objects"
    t.index ["taggable_type", "taggable_id"], name: "index_taggings_on_taggable"
    t.index ["user_id"], name: "index_taggings_on_user_id"
  end

  create_table "tags", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.uuid "organisation_id", null: false
    t.uuid "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name", "organisation_id"], name: "index_tags_on_name_and_organisation_id", unique: true
    t.index ["organisation_id"], name: "index_tags_on_organisation_id"
    t.index ["user_id"], name: "index_tags_on_user_id"
  end

  create_table "term_applications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "meeting_id", null: false
    t.uuid "project_id"
    t.uuid "glossary_term_id"
    t.string "term", null: false
    t.string "heard", null: false
    t.string "normalized_heard", null: false
    t.integer "replaced_count", default: 1, null: false
    t.string "source", default: "device", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["glossary_term_id", "normalized_heard"], name: "index_term_applications_on_term_and_heard"
    t.index ["meeting_id", "normalized_heard", "heard"], name: "index_term_applications_on_meeting_and_heard", unique: true
    t.index ["organisation_id"], name: "index_term_applications_on_organisation_id"
    t.index ["project_id"], name: "index_term_applications_on_project_id"
    t.check_constraint "replaced_count >= 1", name: "term_applications_count_positive"
    t.check_constraint "source::text = 'device'::text", name: "term_applications_source_known"
  end

  create_table "term_corrections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "glossary_term_id", null: false
    t.uuid "project_id"
    t.string "heard", null: false
    t.string "normalized_heard", null: false
    t.uuid "person_id"
    t.uuid "user_id"
    t.uuid "meeting_id"
    t.integer "line_index"
    t.integer "char_offset"
    t.string "transcript_digest"
    t.integer "replaced_count", default: 1, null: false
    t.uuid "corrected_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "confirmed", null: false
    t.string "origin", default: "meeting", null: false
    t.index ["corrected_by_id"], name: "index_term_corrections_on_corrected_by_id"
    t.index ["glossary_term_id", "normalized_heard"], name: "index_term_corrections_on_term_and_heard"
    t.index ["meeting_id"], name: "index_term_corrections_on_meeting_id"
    t.index ["organisation_id"], name: "index_term_corrections_on_organisation_id"
    t.index ["person_id"], name: "index_term_corrections_on_person_id"
    t.index ["project_id"], name: "index_term_corrections_on_project_id"
    t.index ["user_id"], name: "index_term_corrections_on_user_id"
    t.check_constraint "num_nonnulls(person_id, user_id) <= 1", name: "term_corrections_one_speaker"
    t.check_constraint "origin::text = ANY (ARRAY['meeting'::character varying, 'extraction'::character varying, 'import'::character varying]::text[])", name: "term_corrections_origin_known"
    t.check_constraint "status::text = ANY (ARRAY['proposed'::character varying::text, 'confirmed'::character varying::text])", name: "term_corrections_status_known"
  end

  create_table "ticket_assignments", force: :cascade do |t|
    t.uuid "ticket_id", null: false
    t.uuid "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ticket_id", "user_id"], name: "index_ticket_assignments_on_ticket_id_and_user_id", unique: true
    t.index ["ticket_id"], name: "index_ticket_assignments_on_ticket_id"
    t.index ["user_id"], name: "index_ticket_assignments_on_user_id"
  end

  create_table "ticket_attribute_definitions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "field_type", null: false
    t.jsonb "labels", default: {}
    t.jsonb "options", default: {}
    t.jsonb "validation_rules", default: {}
    t.jsonb "visibility_rules", default: {}
    t.integer "position", default: 0
    t.string "section"
    t.string "width", default: "full"
    t.boolean "active", default: true
    t.boolean "system", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "project_id", null: false
    t.index ["position"], name: "index_ticket_attribute_definitions_on_position"
    t.index ["project_id", "active"], name: "index_ticket_attribute_definitions_on_project_id_and_active"
    t.index ["project_id", "name"], name: "index_ticket_attribute_definitions_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_ticket_attribute_definitions_on_project_id"
  end

  create_table "ticket_bulk_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "project_id", null: false
    t.uuid "user_id"
    t.uuid "undo_of_id"
    t.jsonb "change_list", default: [], null: false
    t.jsonb "results", default: {}, null: false
    t.integer "changed_count", default: 0, null: false
    t.integer "failed_count", default: 0, null: false
    t.datetime "undone_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "kind", default: "change", null: false
    t.index ["organisation_id"], name: "index_ticket_bulk_runs_on_organisation_id"
    t.index ["project_id"], name: "index_ticket_bulk_runs_on_project_id"
    t.index ["undo_of_id"], name: "index_ticket_bulk_runs_on_undo_of_id"
    t.index ["user_id"], name: "index_ticket_bulk_runs_on_user_id"
  end

  create_table "ticket_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ticket_id", null: false
    t.uuid "organisation_id", null: false
    t.text "plain_text_version"
    t.integer "plain_text_word_count"
    t.boolean "create_embeddings", default: true
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organisation_id"], name: "index_ticket_documents_on_organisation_id"
    t.index ["ticket_id", "created_at"], name: "index_ticket_documents_on_ticket_id_and_created_at"
  end

  create_table "ticket_relations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organisation_id", null: false
    t.uuid "source_ticket_id", null: false
    t.uuid "target_ticket_id", null: false
    t.integer "relation_type", null: false
    t.integer "delay_days"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id), relation_type", name: "index_ticket_relations_single_edge_per_pair", unique: true, where: "(relation_type = ANY (ARRAY[1, 2]))"
    t.index ["organisation_id"], name: "index_ticket_relations_on_organisation_id"
    t.index ["source_ticket_id", "relation_type"], name: "index_ticket_relations_on_source_and_type"
    t.index ["source_ticket_id", "target_ticket_id", "relation_type"], name: "index_ticket_relations_unique_edge", unique: true
    t.index ["target_ticket_id", "relation_type"], name: "index_ticket_relations_on_target_and_type"
    t.check_constraint "delay_days IS NULL OR relation_type = 3", name: "ticket_relations_delay_only_for_precedes"
    t.check_constraint "source_ticket_id <> target_ticket_id", name: "ticket_relations_not_self_referential"
  end

  create_table "tickets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title", null: false
    t.uuid "project_id", null: false
    t.text "summary"
    t.uuid "organisation_id", null: false
    t.uuid "creator_id", null: false
    t.uuid "updater_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "embeddings_creation_flag"
    t.text "embedding_creation_error"
    t.integer "number"
    t.jsonb "custom_attributes", default: {}, null: false
    t.string "ticket_type", default: "support", null: false
    t.uuid "parent_id"
    t.datetime "summary_generated_at"
    t.index "((custom_attributes IS NOT NULL))", name: "index_tickets_on_custom_attrs_not_null", where: "(custom_attributes IS NOT NULL)"
    t.index "organisation_id, ((custom_attributes IS NOT NULL))", name: "index_tickets_on_org_and_custom_attrs_exists"
    t.index "project_id, ((custom_attributes IS NOT NULL))", name: "index_tickets_on_project_and_custom_attrs_exists"
    t.index "to_tsvector('german'::regconfig, (title)::text)", name: "index_tickets_title_fts", using: :gin
    t.index ["creator_id"], name: "index_tickets_on_creator_id", comment: "Foreign key index for creators"
    t.index ["custom_attributes"], name: "index_tickets_on_custom_attributes", using: :gin
    t.index ["organisation_id", "created_at"], name: "index_tickets_on_org_created", comment: "For organisation-wide ticket views"
    t.index ["organisation_id", "ticket_type"], name: "index_tickets_on_organisation_id_and_ticket_type"
    t.index ["parent_id"], name: "index_tickets_on_parent_id"
    t.index ["project_id", "created_at"], name: "index_tickets_on_project_created", comment: "For ticket listing sorted by creation date"
    t.index ["project_id", "creator_id"], name: "index_tickets_on_project_creator", comment: "For filtering by creator within project"
    t.index ["project_id", "number"], name: "index_tickets_on_project_id_and_number", unique: true
    t.index ["project_id", "title"], name: "index_tickets_on_project_title", comment: "For title-based searches within project"
    t.index ["project_id", "updated_at"], name: "index_tickets_on_project_updated", comment: "For ticket listing sorted by update date"
    t.index ["ticket_type"], name: "index_tickets_on_ticket_type"
  end

  create_table "time_session_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.boolean "billed", default: false, null: false
    t.string "invoice_number"
    t.uuid "organisation_id", null: false
    t.datetime "billed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.uuid "creator_id", null: false
    t.index ["creator_id"], name: "index_time_session_groups_on_creator_id"
    t.index ["organisation_id", "billed"], name: "index_time_session_groups_on_organisation_id_and_billed"
    t.index ["organisation_id", "invoice_number"], name: "index_time_session_groups_on_org_and_invoice_number_unique", unique: true, where: "(invoice_number IS NOT NULL)"
    t.index ["organisation_id"], name: "index_time_session_groups_on_organisation_id"
  end

  create_table "time_session_permissions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "project_id", null: false
    t.boolean "can_create_own", default: true, null: false
    t.boolean "can_view_own", default: true, null: false
    t.boolean "can_edit_own", default: true, null: false
    t.boolean "can_delete_own", default: true, null: false
    t.boolean "can_view_all", default: false, null: false
    t.boolean "can_edit_all", default: false, null: false
    t.boolean "can_delete_all", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_time_session_permissions_on_project"
    t.index ["project_id"], name: "index_time_session_permissions_on_project_id"
    t.index ["user_id", "project_id"], name: "index_time_session_permissions_unique", unique: true
    t.index ["user_id"], name: "index_time_session_permissions_on_user_id"
  end

  create_table "time_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "occurred_on", null: false
    t.integer "duration", null: false
    t.text "description"
    t.datetime "billed_at"
    t.string "invoice_number"
    t.datetime "deleted_at"
    t.uuid "project_id", null: false
    t.uuid "ticket_id"
    t.uuid "creator_id", null: false
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "time_session_group_id"
    t.boolean "billed", default: false, null: false
    t.text "customer_description"
    t.uuid "meeting_id"
    t.index ["billed"], name: "index_time_sessions_on_billed"
    t.index ["creator_id", "occurred_on"], name: "index_time_sessions_on_creator_id_and_occurred_on"
    t.index ["creator_id"], name: "index_time_sessions_on_creator_id"
    t.index ["customer_description"], name: "index_time_sessions_on_customer_description", where: "(customer_description IS NOT NULL)"
    t.index ["deleted_at", "project_id", "occurred_on"], name: "index_time_sessions_active_project_occurred", comment: "For active time sessions in project chronologically"
    t.index ["deleted_at"], name: "index_time_sessions_on_deleted_at"
    t.index ["meeting_id"], name: "index_time_sessions_on_meeting_id"
    t.index ["organisation_id"], name: "index_time_sessions_on_organisation_id"
    t.index ["project_id", "billed_at"], name: "index_time_sessions_on_project_billed", comment: "For billing status queries"
    t.index ["project_id", "occurred_on"], name: "index_time_sessions_on_project_occurred", comment: "For project time tracking views"
    t.index ["project_id"], name: "index_time_sessions_on_project_id"
    t.index ["ticket_id", "occurred_on"], name: "index_time_sessions_on_ticket_occurred", comment: "For loading ticket time sessions chronologically"
    t.index ["ticket_id"], name: "index_time_sessions_on_ticket_id", comment: "Foreign key index for time session tickets"
    t.index ["time_session_group_id"], name: "index_time_sessions_on_time_session_group_id"
    t.check_constraint "NOT (ticket_id IS NOT NULL AND meeting_id IS NOT NULL)", name: "time_sessions_single_subject"
  end

  create_table "user_activities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "organisation_id"
    t.string "action", null: false
    t.string "category", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.string "session_id"
    t.jsonb "metadata", default: {}
    t.jsonb "attribute_changes", default: {}
    t.string "trackable_type"
    t.uuid "trackable_id"
    t.string "status", default: "success"
    t.text "failure_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category", "created_at"], name: "idx_user_activities_on_category_and_time"
    t.index ["created_at"], name: "idx_user_activities_on_created_at"
    t.index ["ip_address", "created_at"], name: "idx_user_activities_on_ip_and_time"
    t.index ["organisation_id", "created_at"], name: "idx_user_activities_on_org_and_time"
    t.index ["organisation_id"], name: "index_user_activities_on_organisation_id"
    t.index ["session_id"], name: "idx_user_activities_on_session"
    t.index ["trackable_type", "trackable_id"], name: "idx_user_activities_on_trackable"
    t.index ["user_id", "action", "created_at"], name: "idx_user_activities_on_user_action_time"
    t.index ["user_id", "created_at"], name: "idx_user_activities_on_user_and_time"
    t.index ["user_id"], name: "index_user_activities_on_user_id"
  end

  create_table "user_data_exports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "status", default: "pending", null: false
    t.string "error_message"
    t.datetime "completed_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "created_at"], name: "index_user_data_exports_on_user_id_and_created_at"
    t.index ["user_id"], name: "idx_user_data_exports_one_active_per_user", unique: true, where: "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('processing'::character varying)::text]))"
    t.index ["user_id"], name: "index_user_data_exports_on_user_id"
  end

  create_table "user_deletions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "deleted_user_id", null: false
    t.string "deleter_type", null: false
    t.uuid "deleter_id", null: false
    t.string "source", null: false
    t.text "reason"
    t.datetime "deleted_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "scheduled_at"
    t.datetime "executed_at"
    t.datetime "canceled_at"
    t.text "cancellation_reason"
    t.index ["deleted_at"], name: "index_user_deletions_on_deleted_at"
    t.index ["deleted_user_id"], name: "index_user_deletions_on_deleted_user_id"
    t.index ["deleter_type", "deleter_id"], name: "index_user_deletions_on_deleter_type_and_deleter_id"
    t.index ["source"], name: "index_user_deletions_on_source"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "first_name"
    t.string "last_name"
    t.boolean "is_ai", default: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "active", default: true, null: false
    t.boolean "deletion_recommended", default: false, null: false
    t.uuid "invited_by_user_id"
    t.uuid "invited_by_org_id"
    t.datetime "deleted_at"
    t.jsonb "preferences", default: {}, null: false
    t.datetime "scheduled_deletion_at"
    t.datetime "deletion_canceled_at"
    t.text "deletion_reason"
    t.string "timezone", default: "Europe/Berlin"
    t.string "language_preference", default: "de", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.string "unlock_token"
    t.datetime "locked_at"
    t.datetime "changelog_last_read_at"
    t.integer "session_timeout_minutes", default: 30, null: false
    t.datetime "terms_accepted_at"
    t.datetime "last_seen_at"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.string "email_visibility", default: "login", null: false
    t.string "contact_email"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["deletion_recommended"], name: "index_users_on_deletion_recommended"
    t.index ["email"], name: "index_users_on_email_active", unique: true, where: "(deleted_at IS NULL)"
    t.index ["invited_by_org_id"], name: "index_users_on_invited_by_org_id"
    t.index ["invited_by_user_id"], name: "index_users_on_invited_by_user_id"
    t.index ["language_preference"], name: "index_users_on_language_preference"
    t.index ["last_seen_at"], name: "index_users_on_last_seen_at"
    t.index ["preferences"], name: "index_users_on_preferences", using: :gin
    t.index ["scheduled_deletion_at"], name: "index_users_on_scheduled_deletion_at"
    t.index ["timezone"], name: "index_users_on_timezone"
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
    t.check_constraint "email_visibility::text = ANY (ARRAY['login'::character varying::text, 'contact'::character varying::text, 'none'::character varying::text])", name: "users_email_visibility_known"
  end

  create_table "view_configurations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "project_id"
    t.uuid "organisation_id", null: false
    t.string "view_type", default: "tickets"
    t.jsonb "table_columns", default: []
    t.jsonb "list_columns", default: []
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "header_columns", default: []
    t.string "view_mode", default: "table"
    t.uuid "kanban_attribute_definition_id"
    t.jsonb "detail_settings", default: {}
    t.jsonb "pinned_columns", default: []
    t.index ["header_columns"], name: "index_view_configurations_on_header_columns", using: :gin
    t.index ["list_columns"], name: "index_view_configurations_on_list_columns", using: :gin
    t.index ["organisation_id"], name: "index_view_configurations_on_organisation_id"
    t.index ["project_id"], name: "index_view_configurations_on_project_id"
    t.index ["table_columns"], name: "index_view_configurations_on_table_columns", using: :gin
    t.index ["user_id", "organisation_id", "view_type"], name: "index_view_configs_on_user_organisation_type_without_project", unique: true, where: "(project_id IS NULL)"
    t.index ["user_id", "project_id", "view_type"], name: "index_view_configs_on_user_project_type", unique: true
    t.index ["user_id"], name: "index_view_configurations_on_user_id"
  end

  create_table "view_states", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "key", null: false
    t.jsonb "state", default: {}
    t.string "viewable_type", null: false
    t.uuid "viewable_id", null: false
    t.uuid "organisation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_view_states_on_key"
    t.index ["organisation_id"], name: "index_view_states_on_organisation_id"
    t.index ["user_id", "key", "viewable_type", "viewable_id", "organisation_id"], name: "index_view_states_unique", unique: true
    t.index ["user_id"], name: "index_view_states_on_user_id"
    t.index ["viewable_type", "viewable_id"], name: "index_view_states_on_viewable"
  end

  add_foreign_key "account_discounts", "accounts"
  add_foreign_key "accounts", "users", column: "business_confirmed_by_id", on_delete: :nullify
  add_foreign_key "accounts", "users", column: "owner_id", on_delete: :nullify
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activities", "organisations"
  add_foreign_key "activities", "users", column: "actor_id"
  add_foreign_key "ai_credential_contract_documents", "ai_credential_contracts"
  add_foreign_key "ai_credential_contract_documents", "ai_credential_documents"
  add_foreign_key "ai_credential_contracts", "ai_credentials"
  add_foreign_key "ai_credential_documents", "ai_credentials"
  add_foreign_key "ai_package_tiers", "ai_credentials", column: "chat_credential_id"
  add_foreign_key "ai_package_tiers", "ai_packages"
  add_foreign_key "ai_packages", "ai_credentials", column: "embedding_credential_id"
  add_foreign_key "ai_usage_rollups", "accounts"
  add_foreign_key "ai_usages", "ai_credentials"
  add_foreign_key "ai_usages", "organisations"
  add_foreign_key "ai_usages", "users", on_delete: :nullify
  add_foreign_key "analysis_prompts", "organisations"
  add_foreign_key "analysis_prompts", "users", column: "creator_id", on_delete: :nullify
  add_foreign_key "chat_style_preferences", "organisations"
  add_foreign_key "chat_style_preferences", "prompt_personas", on_delete: :nullify
  add_foreign_key "chat_style_preferences", "users", on_delete: :cascade
  add_foreign_key "chats", "project_repositories"
  add_foreign_key "chats", "projects", column: "scope_project_id", on_delete: :nullify
  add_foreign_key "chats", "prompt_personas", on_delete: :nullify
  add_foreign_key "chats", "tickets", column: "scope_ticket_id", on_delete: :nullify
  add_foreign_key "chats", "users"
  add_foreign_key "code_symbols", "organisations"
  add_foreign_key "code_symbols", "project_repositories"
  add_foreign_key "codebase_import_files", "organisations"
  add_foreign_key "codebase_import_files", "projects"
  add_foreign_key "codebase_import_files", "users"
  add_foreign_key "codebase_import_mappings", "organisations"
  add_foreign_key "codebase_uploads", "organisations"
  add_foreign_key "content_embeddings", "organisations", on_delete: :cascade
  add_foreign_key "dashboard_configurations", "organisations"
  add_foreign_key "dashboard_configurations", "projects"
  add_foreign_key "dashboard_configurations", "users"
  add_foreign_key "document_versions", "users"
  add_foreign_key "documentation_assets", "documentation_sets"
  add_foreign_key "documentation_assets", "organisations"
  add_foreign_key "documentation_commits", "documentation_sets"
  add_foreign_key "documentation_commits", "organisations"
  add_foreign_key "documentation_pages", "documentation_sets"
  add_foreign_key "documentation_pages", "organisations"
  add_foreign_key "documentation_set_views", "documentation_sets"
  add_foreign_key "documentation_set_views", "organisations"
  add_foreign_key "documentation_set_views", "users", on_delete: :cascade
  add_foreign_key "documentation_sets", "organisations"
  add_foreign_key "documentation_sets", "project_repositories"
  add_foreign_key "documentation_sets", "projects"
  add_foreign_key "documentation_sync_runs", "documentation_sets"
  add_foreign_key "documentation_sync_runs", "organisations"
  add_foreign_key "documentation_sync_runs", "users", column: "triggered_by_user_id", on_delete: :nullify
  add_foreign_key "documents", "document_versions", column: "current_version_id"
  add_foreign_key "documents", "organisations"
  add_foreign_key "documents", "projects"
  add_foreign_key "documents", "users", column: "creator_id"
  add_foreign_key "email_logs", "email_logs", column: "resent_from_id"
  add_foreign_key "email_logs", "notifications"
  add_foreign_key "email_logs", "organisations"
  add_foreign_key "embedding_spaces", "ai_credentials", on_delete: :nullify
  add_foreign_key "embedding_spaces", "organisations", on_delete: :cascade
  add_foreign_key "founder_signups", "accounts"
  add_foreign_key "fragments", "organisations"
  add_foreign_key "glossary_extraction_runs", "organisations", on_delete: :cascade
  add_foreign_key "glossary_extraction_runs", "users", column: "started_by_id", on_delete: :nullify
  add_foreign_key "glossary_proposal_sources", "glossary_proposals", on_delete: :cascade
  add_foreign_key "glossary_proposal_sources", "organisations", on_delete: :cascade
  add_foreign_key "glossary_proposal_sources", "projects", on_delete: :nullify
  add_foreign_key "glossary_proposals", "glossary_extraction_runs", on_delete: :nullify
  add_foreign_key "glossary_proposals", "glossary_terms", on_delete: :nullify
  add_foreign_key "glossary_proposals", "organisations", on_delete: :cascade
  add_foreign_key "glossary_proposals", "users", column: "decided_by_id", on_delete: :nullify
  add_foreign_key "glossary_terms", "organisations", on_delete: :cascade
  add_foreign_key "glossary_terms", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "imported_objects", "organisations"
  add_foreign_key "mcp_idempotency_keys", "personal_access_tokens"
  add_foreign_key "meeting_analyses", "analysis_prompts", on_delete: :nullify
  add_foreign_key "meeting_analyses", "meetings"
  add_foreign_key "meeting_analyses", "organisations"
  add_foreign_key "meeting_analyses", "users", column: "creator_id", on_delete: :nullify
  add_foreign_key "meeting_analyses", "users", column: "visible_to_user_id", on_delete: :nullify
  add_foreign_key "meeting_participant_claim_rejections", "organisations"
  add_foreign_key "meeting_participant_claim_rejections", "users", on_delete: :cascade
  add_foreign_key "meeting_participants", "meetings"
  add_foreign_key "meeting_participants", "organisations"
  add_foreign_key "meeting_participants", "people", on_delete: :nullify
  add_foreign_key "meeting_participants", "users", on_delete: :nullify
  add_foreign_key "meeting_ticket_suggestion_runs", "chatposts", on_delete: :cascade
  add_foreign_key "meeting_ticket_suggestion_runs", "meetings", on_delete: :cascade
  add_foreign_key "meeting_ticket_suggestion_runs", "organisations"
  add_foreign_key "meeting_ticket_suggestions", "meeting_ticket_suggestion_runs", on_delete: :nullify
  add_foreign_key "meeting_ticket_suggestions", "meetings"
  add_foreign_key "meeting_ticket_suggestions", "organisations"
  add_foreign_key "meeting_ticket_suggestions", "tickets", column: "created_ticket_id", on_delete: :nullify
  add_foreign_key "meeting_ticket_suggestions", "tickets", column: "similar_ticket_id", on_delete: :nullify
  add_foreign_key "meetings", "organisations"
  add_foreign_key "meetings", "projects"
  add_foreign_key "meetings", "users", column: "creator_id"
  add_foreign_key "memberships", "roles"
  add_foreign_key "note_versions", "notes"
  add_foreign_key "note_versions", "users", column: "author_id"
  add_foreign_key "notes", "users", column: "creator_id"
  add_foreign_key "notification_preferences", "organisations"
  add_foreign_key "notification_preferences", "users"
  add_foreign_key "notification_subscriptions", "organisations"
  add_foreign_key "notification_subscriptions", "users"
  add_foreign_key "notification_subscriptions", "users", column: "subscribed_by_id"
  add_foreign_key "notifications", "organisations"
  add_foreign_key "notifications", "projects"
  add_foreign_key "notifications", "users", column: "actor_id"
  add_foreign_key "notifications", "users", column: "recipient_id"
  add_foreign_key "organisations", "accounts"
  add_foreign_key "organisations", "ai_packages"
  add_foreign_key "organisations", "embedding_spaces", column: "active_embedding_space_id", on_delete: :nullify
  add_foreign_key "organisations", "projects", column: "meeting_inbox_project_id", on_delete: :nullify
  add_foreign_key "organisations", "users", column: "ai_activated_by_id", on_delete: :nullify
  add_foreign_key "organisations", "users", column: "ai_package_selected_by_id", on_delete: :nullify
  add_foreign_key "outbox_events", "activities"
  add_foreign_key "outbox_events", "organisations"
  add_foreign_key "overview_configurations", "organisations"
  add_foreign_key "overview_configurations", "users"
  add_foreign_key "people", "organisations"
  add_foreign_key "people", "users", column: "creator_id", on_delete: :nullify
  add_foreign_key "people", "users", column: "updater_id", on_delete: :nullify
  add_foreign_key "people", "users", on_delete: :nullify
  add_foreign_key "permissions", "roles"
  add_foreign_key "personal_access_token_organisations", "organisations"
  add_foreign_key "personal_access_token_organisations", "personal_access_tokens"
  add_foreign_key "personal_access_token_projects", "personal_access_tokens"
  add_foreign_key "personal_access_token_projects", "projects"
  add_foreign_key "personal_access_tokens", "users"
  add_foreign_key "personal_tasks", "organisations"
  add_foreign_key "personal_tasks", "users", on_delete: :cascade
  add_foreign_key "post_reactions", "organisations"
  add_foreign_key "post_reactions", "posts", on_delete: :cascade
  add_foreign_key "post_reactions", "users", on_delete: :cascade
  add_foreign_key "post_reads", "organisations"
  add_foreign_key "post_reads", "posts", on_delete: :cascade
  add_foreign_key "post_reads", "users", on_delete: :cascade
  add_foreign_key "posts", "users", column: "visible_to_user_id"
  add_foreign_key "price_tiers", "price_lists"
  add_foreign_key "project_capabilities", "organisations"
  add_foreign_key "project_capabilities", "projects"
  add_foreign_key "project_capabilities", "users", column: "edited_by_user_id"
  add_foreign_key "project_index_runs", "organisations"
  add_foreign_key "project_index_runs", "project_repositories"
  add_foreign_key "project_index_runs", "users", column: "triggered_by_user_id", on_delete: :nullify
  add_foreign_key "project_indexes", "organisations"
  add_foreign_key "project_indexes", "project_repositories"
  add_foreign_key "project_layer4_visions", "organisations"
  add_foreign_key "project_layer4_visions", "projects"
  add_foreign_key "project_layer4_visions", "users", column: "edited_by_user_id"
  add_foreign_key "project_permissions", "projects"
  add_foreign_key "project_permissions", "users"
  add_foreign_key "project_repositories", "organisations"
  add_foreign_key "project_repositories", "projects"
  add_foreign_key "project_repositories", "users", column: "connected_by_user_id"
  add_foreign_key "projects", "users", column: "archived_by_id"
  add_foreign_key "prompt_personas", "organisations"
  add_foreign_key "roles", "organisations"
  add_foreign_key "seat_events", "accounts"
  add_foreign_key "seat_snapshots", "accounts"
  add_foreign_key "smart_folder_rule_groups", "smart_folders"
  add_foreign_key "smart_folder_rules", "smart_folder_rule_groups"
  add_foreign_key "smart_folder_shares", "smart_folders"
  add_foreign_key "smart_folder_shares", "users"
  add_foreign_key "smart_folders", "organisations"
  add_foreign_key "smart_folders", "projects"
  add_foreign_key "smart_folders", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_processes", column: "process_id", on_delete: :nullify
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_processes", "solid_queue_processes", column: "supervisor_id", on_delete: :nullify
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "taggings", "tags"
  add_foreign_key "taggings", "users"
  add_foreign_key "tags", "organisations"
  add_foreign_key "tags", "users"
  add_foreign_key "term_applications", "glossary_terms", on_delete: :nullify
  add_foreign_key "term_applications", "meetings", on_delete: :cascade
  add_foreign_key "term_applications", "organisations", on_delete: :cascade
  add_foreign_key "term_applications", "projects", on_delete: :nullify
  add_foreign_key "term_corrections", "glossary_terms", on_delete: :cascade
  add_foreign_key "term_corrections", "meetings", on_delete: :nullify
  add_foreign_key "term_corrections", "organisations", on_delete: :cascade
  add_foreign_key "term_corrections", "people", on_delete: :nullify
  add_foreign_key "term_corrections", "projects", on_delete: :nullify
  add_foreign_key "term_corrections", "users", column: "corrected_by_id", on_delete: :nullify
  add_foreign_key "term_corrections", "users", on_delete: :nullify
  add_foreign_key "ticket_attribute_definitions", "projects"
  add_foreign_key "ticket_bulk_runs", "organisations"
  add_foreign_key "ticket_bulk_runs", "projects"
  add_foreign_key "ticket_bulk_runs", "ticket_bulk_runs", column: "undo_of_id"
  add_foreign_key "ticket_bulk_runs", "users", on_delete: :nullify
  add_foreign_key "ticket_documents", "organisations"
  add_foreign_key "ticket_documents", "tickets"
  add_foreign_key "ticket_relations", "organisations"
  add_foreign_key "ticket_relations", "tickets", column: "source_ticket_id", on_delete: :cascade
  add_foreign_key "ticket_relations", "tickets", column: "target_ticket_id", on_delete: :cascade
  add_foreign_key "tickets", "tickets", column: "parent_id", on_delete: :nullify
  add_foreign_key "time_session_groups", "organisations"
  add_foreign_key "time_session_groups", "users", column: "creator_id"
  add_foreign_key "time_session_permissions", "projects"
  add_foreign_key "time_session_permissions", "users"
  add_foreign_key "time_sessions", "meetings", on_delete: :nullify
  add_foreign_key "time_sessions", "organisations"
  add_foreign_key "time_sessions", "projects"
  add_foreign_key "time_sessions", "tickets"
  add_foreign_key "time_sessions", "time_session_groups"
  add_foreign_key "time_sessions", "users", column: "creator_id"
  add_foreign_key "user_activities", "organisations"
  add_foreign_key "user_activities", "users"
  add_foreign_key "user_data_exports", "users", on_delete: :cascade
  add_foreign_key "user_deletions", "users", column: "deleted_user_id"
  add_foreign_key "users", "organisations", column: "invited_by_org_id"
  add_foreign_key "users", "users", column: "invited_by_user_id"
  add_foreign_key "view_configurations", "organisations"
  add_foreign_key "view_configurations", "projects"
  add_foreign_key "view_configurations", "ticket_attribute_definitions", column: "kanban_attribute_definition_id", on_delete: :nullify
  add_foreign_key "view_configurations", "users"
  add_foreign_key "view_states", "organisations"
  add_foreign_key "view_states", "users"
end
