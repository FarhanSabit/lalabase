# frozen_string_literal: true

pin 'application', to: 'application.js'
# pin '@rails/ujs', to: 'rails-ujs.js'  # Not used with Turbo
pin '@hotwired/turbo-rails', to: 'turbo.min.js'
pin '@rails/actiontext', to: 'actiontext.esm.js'
pin '@rails/activestorage', to: 'activestorage.esm.js'
pin 'lexxy', to: 'lexxy.js' # Wiki notes editor (gem-provided ESM, self-registers <lexxy-editor>)

pin '@hotwired/stimulus', to: 'stimulus.min.js', preload: true
pin '@hotwired/stimulus-loading', to: 'stimulus-loading.js', preload: true
pin 'i18n', to: 'lib/i18n.js'
# Meetings Slice 1b: pure, testable participant parser + name normalizer. Both are
# imported by meeting_participants_controller via these bare specifiers; the JS
# unit tests import the same files by path (node:test). No cross-module import
# between them (normalize is injected) so neither breaks in production or node.
pin 'meetings/participant_parser', to: 'lib/meetings/participant_parser.js'
pin 'meetings/name_normalizer', to: 'lib/meetings/name_normalizer.js'
# Meetings Slice 5: pure LLM-detection merge rule, same inject-normalize pattern.
pin 'meetings/participant_merge', to: 'lib/meetings/participant_merge.js'
pin 'time_session_modal', to: 'lib/time_session_modal.js'
# The project select of "Neues Meeting" on "Alle Meetings": which form its frame
# shows, pure so spec/javascript can test it.
pin 'meeting_project_select', to: 'lib/meeting_project_select.js'
# NeoAutosuggest's server search (the ticket picker of the "Link" modal): confirmed
# choice, request sequence, debounce and abort, pure so spec/javascript can test them.
pin 'autosuggest_search', to: 'lib/autosuggest_search.js'
pin 'rich_text_embed_accept', to: 'lib/rich_text_embed_accept.js'
pin 'rich_text_zoom', to: 'lib/rich_text_zoom.js'
pin 'form_snapshot', to: 'lib/form_snapshot.js'
pin 'filter_bar/utils', to: 'lib/filter_bar/utils.js'
pin 'filter_bar/url_builder', to: 'lib/filter_bar/url_builder.js'
pin 'filter_bar/menu_renderer', to: 'lib/filter_bar/menu_renderer.js'
pin 'list_frame_reload', to: 'lib/list_frame_reload.js'
pin 'ticket_selection', to: 'lib/ticket_selection.js'
pin 'ticket_bulk_draft', to: 'lib/ticket_bulk_draft.js'
pin 'new_tag_name', to: 'lib/new_tag_name.js'
# Row index, limit and value field of the additional details in the people form.
pin 'person_details', to: 'lib/person_details.js'
pin 'filter_bar/chip_renderer', to: 'lib/filter_bar/chip_renderer.js'
pin 'column_picker/fit', to: 'lib/column_picker/fit.js'
pin 'column_picker/order', to: 'lib/column_picker/order.js'
pin 'assignee_menu/diff', to: 'lib/assignee_menu/diff.js'
pin 'kanban/keyboard', to: 'lib/kanban/keyboard.js'
pin 'list_row/address', to: 'lib/list_row/address.js'
# The lane's parameter groups and what Back restores (doc/dateivorschau_plan.md, D9 and D2),
# and which controls take the list state beside an open lane (filter_context).
pin 'lane/params', to: 'lib/lane/params.js'
pin 'lane/history', to: 'lib/lane/history.js'
pin 'lane/filter_context', to: 'lib/lane/filter_context.js'
pin 'lane/meeting_panel_stage', to: 'lib/lane/meeting_panel_stage.js'
# Who takes an Escape: the topmost menu, modal or drawer, before the lane.
pin 'escape_owner', to: 'lib/escape_owner.js'
# The document forms' drop zone: the title a file suggests (S4 of doc/dokumentansicht_plan.md).
pin 'upload_zone/title', to: 'lib/upload_zone/title.js'
# The folder target a type condition becomes (pure, node:test).
pin 'filter_bar/save_target', to: 'lib/filter_bar/save_target.js'
# The state model of the bar (saved, ad hoc, dropped, effective), pure so
# spec/javascript can pin the comparison rule the save row rests on.
pin 'filter_bar/change_set', to: 'lib/filter_bar/change_set.js'
# The wording of the save row (pure, node:test), the save row's HTML, and the
# way back after a tab switch (sessionStorage hand-off, pure with the storage
# injected).
pin 'filter_bar/change_sentence', to: 'lib/filter_bar/change_sentence.js'
pin 'filter_bar/save_row', to: 'lib/filter_bar/save_row.js'
pin 'filter_bar/undo_handoff', to: 'lib/filter_bar/undo_handoff.js'
# (the old bar behind the per-user flag, doc/filterleiste_s1_s4_plan.md).
# Deleted together with the flag.
# Shared dialog a11y primitives (tab trap + aria-live announce), imported by
# help_modal_controller and contextual_help_drawer_controller.
pin 'dialog_a11y', to: 'lib/dialog_a11y.js'
# Swipe-to-dismiss mixin for notification items. Imported by neo_notification_controller
# via this bare specifier — NEVER a relative "../mixins/swipeable" import: relative paths
# bypass importmap resolution and 404 on the undigested URL in production.
pin 'mixins/swipeable', to: 'mixins/swipeable.js'
# The mobile/desktop boundary (768px), imported by viewport_controller and
# kanban_board_controller. Same rule as above: bare specifier only, never a relative import.
pin 'breakpoints', to: 'lib/breakpoints.js'
# "At most one row shows its actions", imported by hover_reveal_controller.
# Bare specifier only, same rule as above.
pin 'hover_reveal', to: 'lib/hover_reveal.js'

# Which element a bulk checkbox of the time list belongs to, imported by
# time_session_bulk_controller. Markers of our own instead of layout facts.
pin 'time_session_bulk_markers', to: 'lib/time_session_bulk_markers.js'

# Which rows of the time list the reader had open, imported by
# ticket_group_controller so an open row survives the redirect after a bulk
# assignment.
pin 'expanded_rows', to: 'lib/expanded_rows.js'

# Which bookings are picked for a billing, kept across the whole-page navigation
# that a filter pill performs. Same shape as expanded_rows, different question.
pin 'bulk_selection', to: 'lib/bulk_selection.js'

# Rebuilds a filter pill's address from the one the browser is on, imported by
# query_toggle_controller. The pills live outside the Turbo frame and are never
# re-rendered, so their own address goes stale the moment a filter changes.
pin 'query_toggle', to: 'lib/query_toggle.js'

# Which control makes an auto-submit form send itself, imported by
# auto_submit_controller: one without a name never does.
pin 'auto_submit', to: 'lib/auto_submit.js'

# The day count beside the custom period's two date fields, read by
# custom_period_controller. A pure function so node:test can pin the one rule
# that matters: a period INCLUDES both its bounds, the way the filter service
# reads them.
pin 'custom_period', to: 'lib/custom_period.js'
# The match rule of a filter pill's type-to-narrow field. A lib, not just the
# controller, because none of it reaches the server: an inverted empty-term
# check would hide the whole menu of an untouched field and no request spec
# could see it (review of #693).
pin 'filter_menu_search', to: 'lib/filter_menu_search.js'
pin 'menu_fit', to: 'lib/menu_fit.js'
# What the button over a mark in the transcript sends (K4b): the mark, its context and
# offset in characters, and the fields the dialog counts with. Pure, node:test.
pin 'transcript_mark', to: 'lib/transcript_mark.js'

# Development: Load controllers from source directory
if Rails.env.development?
  pin_all_from 'app/javascript/controllers', under: 'controllers', preload: false
else
  # Production/Staging: Pin controllers explicitly to work with asset pipeline
  # CRITICAL: Pin both variants to handle all import scenarios
  pin 'controllers/index', to: 'controllers/index.js'
  pin 'controllers', to: 'controllers/index.js'
  pin 'controllers/application', to: 'controllers/application.js'

  # BEGIN AUTO PINS (generated by rake importmap:auto_pin)
  pin 'controllers/access_matrix_filter_controller', to: 'controllers/access_matrix_filter_controller.js'
  pin 'controllers/admin_ai_credential_preset_controller', to: 'controllers/admin_ai_credential_preset_controller.js'
  pin 'controllers/admin_ai_credential_token_field_controller', to: 'controllers/admin_ai_credential_token_field_controller.js'
  pin 'controllers/admin_user_delete_modal_controller', to: 'controllers/admin_user_delete_modal_controller.js'
  pin 'controllers/admin_user_form_controller', to: 'controllers/admin_user_form_controller.js'
  pin 'controllers/ai_configuration_fields_controller', to: 'controllers/ai_configuration_fields_controller.js'
  pin 'controllers/analysis_result_controller', to: 'controllers/analysis_result_controller.js'
  pin 'controllers/assistant_analysis_controller', to: 'controllers/assistant_analysis_controller.js'
  pin 'controllers/assistant_panel_controller', to: 'controllers/assistant_panel_controller.js'
  pin 'controllers/assistant_suggestion_composer_controller', to: 'controllers/assistant_suggestion_composer_controller.js'
  pin 'controllers/assistant_suggestion_result_controller', to: 'controllers/assistant_suggestion_result_controller.js'
  pin 'controllers/assistant_trigger_controller', to: 'controllers/assistant_trigger_controller.js'
  pin 'controllers/attribute_form_controller', to: 'controllers/attribute_form_controller.js'
  pin 'controllers/auth_password_controller', to: 'controllers/auth_password_controller.js'
  pin 'controllers/auto_dismiss_controller', to: 'controllers/auto_dismiss_controller.js'
  pin 'controllers/auto_submit_controller', to: 'controllers/auto_submit_controller.js'
  pin 'controllers/avatar_fallback_controller', to: 'controllers/avatar_fallback_controller.js'
  pin 'controllers/billing_form_controller', to: 'controllers/billing_form_controller.js'
  pin 'controllers/billing_modal_controller', to: 'controllers/billing_modal_controller.js'
  pin 'controllers/changelog_lightbox_controller', to: 'controllers/changelog_lightbox_controller.js'
  pin 'controllers/chat_scroll_controller', to: 'controllers/chat_scroll_controller.js'
  pin 'controllers/clamp_toggle_controller', to: 'controllers/clamp_toggle_controller.js'
  pin 'controllers/clickable_row_controller', to: 'controllers/clickable_row_controller.js'
  pin 'controllers/clipboard_controller', to: 'controllers/clipboard_controller.js'
  pin 'controllers/cockpit_settings_modal_controller', to: 'controllers/cockpit_settings_modal_controller.js'
  pin 'controllers/collapse_controller', to: 'controllers/collapse_controller.js'
  pin 'controllers/column_picker_controller', to: 'controllers/column_picker_controller.js'
  pin 'controllers/contextual_help_drawer_controller', to: 'controllers/contextual_help_drawer_controller.js'
  pin 'controllers/custom_period_controller', to: 'controllers/custom_period_controller.js'
  pin 'controllers/customer_description_edit_controller', to: 'controllers/customer_description_edit_controller.js'
  pin 'controllers/dashboard_inline_edit_controller', to: 'controllers/dashboard_inline_edit_controller.js'
  pin 'controllers/demo_login_controller', to: 'controllers/demo_login_controller.js'
  pin 'controllers/detail_settings_modal_controller', to: 'controllers/detail_settings_modal_controller.js'
  pin 'controllers/details_autoclose_controller', to: 'controllers/details_autoclose_controller.js'
  pin 'controllers/dropdown_controller', to: 'controllers/dropdown_controller.js'
  pin 'controllers/file_upload_controller', to: 'controllers/file_upload_controller.js'
  pin 'controllers/filter_bar_controller', to: 'controllers/filter_bar_controller.js'
  pin 'controllers/filter_menu_search_controller', to: 'controllers/filter_menu_search_controller.js'
  pin 'controllers/frame_error_controller', to: 'controllers/frame_error_controller.js'
  pin 'controllers/frame_search_controller', to: 'controllers/frame_search_controller.js'
  pin 'controllers/glossary_run_poll_controller', to: 'controllers/glossary_run_poll_controller.js'
  pin 'controllers/help_copy_controller', to: 'controllers/help_copy_controller.js'
  pin 'controllers/help_modal_controller', to: 'controllers/help_modal_controller.js'
  pin 'controllers/hover_arrows_controller', to: 'controllers/hover_arrows_controller.js'
  pin 'controllers/hover_reveal_controller', to: 'controllers/hover_reveal_controller.js'
  pin 'controllers/image_lightbox_controller', to: 'controllers/image_lightbox_controller.js'
  pin 'controllers/inbox_bulk_select_controller', to: 'controllers/inbox_bulk_select_controller.js'
  pin 'controllers/inbox_master_item_controller', to: 'controllers/inbox_master_item_controller.js'
  pin 'controllers/index_page_controller', to: 'controllers/index_page_controller.js'
  pin 'controllers/inline_assignees_controller', to: 'controllers/inline_assignees_controller.js'
  pin 'controllers/inline_status_controller', to: 'controllers/inline_status_controller.js'
  pin 'controllers/kanban_board_controller', to: 'controllers/kanban_board_controller.js'
  pin 'controllers/keyboard_navigation_controller', to: 'controllers/keyboard_navigation_controller.js'
  pin 'controllers/landing_faq_controller', to: 'controllers/landing_faq_controller.js'
  pin 'controllers/lane_link_controller', to: 'controllers/lane_link_controller.js'
  pin 'controllers/lane_split_controller', to: 'controllers/lane_split_controller.js'
  pin 'controllers/layout_toggle_controller', to: 'controllers/layout_toggle_controller.js'
  pin 'controllers/list_row_controller', to: 'controllers/list_row_controller.js'
  pin 'controllers/meeting_analysis_composer_controller', to: 'controllers/meeting_analysis_composer_controller.js'
  pin 'controllers/meeting_move_modal_controller', to: 'controllers/meeting_move_modal_controller.js'
  pin 'controllers/meeting_participants_controller', to: 'controllers/meeting_participants_controller.js'
  pin 'controllers/meeting_project_select_controller', to: 'controllers/meeting_project_select_controller.js'
  pin 'controllers/meeting_section_sync_controller', to: 'controllers/meeting_section_sync_controller.js'
  pin 'controllers/member_picker_controller', to: 'controllers/member_picker_controller.js'
  pin 'controllers/membership_workspace_controller', to: 'controllers/membership_workspace_controller.js'
  pin 'controllers/mobile_filter_drawer_controller', to: 'controllers/mobile_filter_drawer_controller.js'
  pin 'controllers/mobile_project_search_controller', to: 'controllers/mobile_project_search_controller.js'
  pin 'controllers/mobile_shell_controller', to: 'controllers/mobile_shell_controller.js'
  pin 'controllers/mobile_ticket_list_controller', to: 'controllers/mobile_ticket_list_controller.js'
  pin 'controllers/modal_controller', to: 'controllers/modal_controller.js'
  pin 'controllers/move_ticket_modal_controller', to: 'controllers/move_ticket_modal_controller.js'
  pin 'controllers/neo_activity_filter_controller', to: 'controllers/neo_activity_filter_controller.js'
  pin 'controllers/neo_ai_disclosure_controller', to: 'controllers/neo_ai_disclosure_controller.js'
  pin 'controllers/neo_autosuggest_controller', to: 'controllers/neo_autosuggest_controller.js'
  pin 'controllers/neo_avatar_crop_controller', to: 'controllers/neo_avatar_crop_controller.js'
  pin 'controllers/neo_button_controller', to: 'controllers/neo_button_controller.js'
  pin 'controllers/neo_chat_composer_controller', to: 'controllers/neo_chat_composer_controller.js'
  pin 'controllers/neo_dropdown_controller', to: 'controllers/neo_dropdown_controller.js'
  pin 'controllers/neo_endless_scroll_controller', to: 'controllers/neo_endless_scroll_controller.js'
  pin 'controllers/neo_flash_controller', to: 'controllers/neo_flash_controller.js'
  pin 'controllers/neo_form_section_controller', to: 'controllers/neo_form_section_controller.js'
  pin 'controllers/neo_inline_popover_controller', to: 'controllers/neo_inline_popover_controller.js'
  pin 'controllers/neo_lane_expand_controller', to: 'controllers/neo_lane_expand_controller.js'
  pin 'controllers/neo_mobile_nav_controller', to: 'controllers/neo_mobile_nav_controller.js'
  pin 'controllers/neo_notification_bulk_action_controller', to: 'controllers/neo_notification_bulk_action_controller.js'
  pin 'controllers/neo_notification_controller', to: 'controllers/neo_notification_controller.js'
  pin 'controllers/neo_notification_filter_controller', to: 'controllers/neo_notification_filter_controller.js'
  pin 'controllers/neo_pagination_controller', to: 'controllers/neo_pagination_controller.js'
  pin 'controllers/neo_personal_access_token_form_controller', to: 'controllers/neo_personal_access_token_form_controller.js'
  pin 'controllers/neo_rich_text_embeds_controller', to: 'controllers/neo_rich_text_embeds_controller.js'
  pin 'controllers/neo_rich_text_zoom_controller', to: 'controllers/neo_rich_text_zoom_controller.js'
  pin 'controllers/neo_select_controller', to: 'controllers/neo_select_controller.js'
  pin 'controllers/neo_tag_controller', to: 'controllers/neo_tag_controller.js'
  pin 'controllers/neo_toggle_controller', to: 'controllers/neo_toggle_controller.js'
  pin 'controllers/neo_writing_surface_controller', to: 'controllers/neo_writing_surface_controller.js'
  pin 'controllers/new_organisation_modal_controller', to: 'controllers/new_organisation_modal_controller.js'
  pin 'controllers/note_actions_controller', to: 'controllers/note_actions_controller.js'
  pin 'controllers/notification_count_data_controller', to: 'controllers/notification_count_data_controller.js'
  pin 'controllers/notification_count_listener_controller', to: 'controllers/notification_count_listener_controller.js'
  pin 'controllers/pane_mark_read_delay_controller', to: 'controllers/pane_mark_read_delay_controller.js'
  pin 'controllers/participant_link_modal_controller', to: 'controllers/participant_link_modal_controller.js'
  pin 'controllers/person_details_controller', to: 'controllers/person_details_controller.js'
  pin 'controllers/personal_tasks_drawer_controller', to: 'controllers/personal_tasks_drawer_controller.js'
  pin 'controllers/popover_controller', to: 'controllers/popover_controller.js'
  pin 'controllers/post_composer_controller', to: 'controllers/post_composer_controller.js'
  pin 'controllers/post_reaction_tooltip_controller', to: 'controllers/post_reaction_tooltip_controller.js'
  pin 'controllers/preview_embed_controller', to: 'controllers/preview_embed_controller.js'
  pin 'controllers/price_ladder_controller', to: 'controllers/price_ladder_controller.js'
  pin 'controllers/project_delete_modal_controller', to: 'controllers/project_delete_modal_controller.js'
  pin 'controllers/query_toggle_controller', to: 'controllers/query_toggle_controller.js'
  pin 'controllers/registration_toggle_controller', to: 'controllers/registration_toggle_controller.js'
  pin 'controllers/reveal_after_frame_controller', to: 'controllers/reveal_after_frame_controller.js'
  pin 'controllers/reveal_more_controller', to: 'controllers/reveal_more_controller.js'
  pin 'controllers/scroll_into_view_controller', to: 'controllers/scroll_into_view_controller.js'
  pin 'controllers/scroll_to_top_controller', to: 'controllers/scroll_to_top_controller.js'
  pin 'controllers/search_overlay_controller', to: 'controllers/search_overlay_controller.js'
  pin 'controllers/session_timeout_controller', to: 'controllers/session_timeout_controller.js'
  pin 'controllers/sidebar_project_accordion_controller', to: 'controllers/sidebar_project_accordion_controller.js'
  pin 'controllers/slim_select_controller', to: 'controllers/slim_select_controller.js'
  pin 'controllers/smart_folder_form_controller', to: 'controllers/smart_folder_form_controller.js'
  pin 'controllers/smart_folder_modal_controller', to: 'controllers/smart_folder_modal_controller.js'
  pin 'controllers/sortable_controller', to: 'controllers/sortable_controller.js'
  pin 'controllers/subscriber_picker_controller', to: 'controllers/subscriber_picker_controller.js'
  pin 'controllers/subtask_quick_add_controller', to: 'controllers/subtask_quick_add_controller.js'
  pin 'controllers/summary_modal_controller', to: 'controllers/summary_modal_controller.js'
  pin 'controllers/tabs_controller', to: 'controllers/tabs_controller.js'
  pin 'controllers/tag_input_controller', to: 'controllers/tag_input_controller.js'
  pin 'controllers/team_member_edit_controller', to: 'controllers/team_member_edit_controller.js'
  pin 'controllers/term_correction_modal_controller', to: 'controllers/term_correction_modal_controller.js'
  pin 'controllers/ticket_bulk_panel_controller', to: 'controllers/ticket_bulk_panel_controller.js'
  pin 'controllers/ticket_description_collapse_controller', to: 'controllers/ticket_description_collapse_controller.js'
  pin 'controllers/ticket_direct_navigation_controller', to: 'controllers/ticket_direct_navigation_controller.js'
  pin 'controllers/ticket_group_controller', to: 'controllers/ticket_group_controller.js'
  pin 'controllers/ticket_meeting_panel_controller', to: 'controllers/ticket_meeting_panel_controller.js'
  pin 'controllers/ticket_pane_links_controller', to: 'controllers/ticket_pane_links_controller.js'
  pin 'controllers/ticket_relation_modal_controller', to: 'controllers/ticket_relation_modal_controller.js'
  pin 'controllers/ticket_selection_controller', to: 'controllers/ticket_selection_controller.js'
  pin 'controllers/ticket_selector_controller', to: 'controllers/ticket_selector_controller.js'
  pin 'controllers/time_session_actions_controller', to: 'controllers/time_session_actions_controller.js'
  pin 'controllers/time_session_bulk_controller', to: 'controllers/time_session_bulk_controller.js'
  pin 'controllers/time_session_form_controller', to: 'controllers/time_session_form_controller.js'
  pin 'controllers/time_session_popup_controller', to: 'controllers/time_session_popup_controller.js'
  pin 'controllers/time_session_row_controller', to: 'controllers/time_session_row_controller.js'
  pin 'controllers/time_sessions_index_controller', to: 'controllers/time_sessions_index_controller.js'
  pin 'controllers/timeline_filter_controller', to: 'controllers/timeline_filter_controller.js'
  pin 'controllers/toggle_controller', to: 'controllers/toggle_controller.js'
  pin 'controllers/transcript_selection_controller', to: 'controllers/transcript_selection_controller.js'
  pin 'controllers/turbo_cache_controller', to: 'controllers/turbo_cache_controller.js'
  pin 'controllers/undefined_url_guard_controller', to: 'controllers/undefined_url_guard_controller.js'
  pin 'controllers/upload_progress_controller', to: 'controllers/upload_progress_controller.js'
  pin 'controllers/upload_zone_controller', to: 'controllers/upload_zone_controller.js'
  pin 'controllers/user_import_controller', to: 'controllers/user_import_controller.js'
  pin 'controllers/user_preferences_controller', to: 'controllers/user_preferences_controller.js'
  pin 'controllers/viewport_controller', to: 'controllers/viewport_controller.js'
  # END AUTO PINS
end

# Vendored dependencies (vendor/javascript) — no runtime CDN (GDPR/render path).
# On version update: load the new file into vendor/javascript + maintain the version comment.
pin 'slim-select', preload: false # @2.9.2 (dist/slimselect.es.js)
pin 'sortablejs', preload: false # @1.15.2 (modular/sortable.esm.js)
