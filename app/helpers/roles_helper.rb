# frozen_string_literal: true

module RolesHelper
  # Returns a user-friendly description of a permission
  def get_permission_description(category, action)
    descriptions = {
      'accounts' => {
        'add_edit_delete_roles' => I18n.t('views.helpers.roles.descriptions.accounts.add_edit_delete_roles'),
        'create_account_admins' => I18n.t('views.helpers.roles.descriptions.accounts.create_account_admins'),
        'manage_users' => I18n.t('views.helpers.roles.descriptions.accounts.manage_users'),
        'remove_account_admins' => I18n.t('views.helpers.roles.descriptions.accounts.remove_account_admins'),
        'close_account' => I18n.t('views.helpers.roles.descriptions.accounts.close_account')
      },
      'projects' => {
        'change_project_properties' => I18n.t('views.helpers.roles.descriptions.projects.change_project_properties'),
        'create_new_projects' => I18n.t('views.helpers.roles.descriptions.projects.create_new_projects'),
        'delete_projects' => I18n.t('views.helpers.roles.descriptions.projects.delete_projects'),
        # New fine-grained permissions
        'read_access_chats_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.read_access_chats_all_projects'),
        'read_access_notes_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.read_access_notes_all_projects'),
        'read_access_tickets_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.read_access_tickets_all_projects'),
        'read_access_meetings_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.read_access_meetings_all_projects'),
        'read_access_documentation_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.read_access_documentation_all_projects'),
        'read_access_documents_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.read_access_documents_all_projects'),
        'read_access_time_tracking_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.read_access_time_tracking_all_projects'),
        'write_access_chats_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.write_access_chats_all_projects'),
        'write_access_notes_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.write_access_notes_all_projects'),
        'write_access_tickets_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.write_access_tickets_all_projects'),
        'write_access_meetings_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.write_access_meetings_all_projects'),
        'write_access_documentation_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.write_access_documentation_all_projects'),
        'write_access_documents_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.write_access_documents_all_projects'),
        'write_access_time_tracking_all_projects' => I18n.t('views.helpers.roles.descriptions.projects.write_access_time_tracking_all_projects')
      },
      'tickets' => {
        'delete_tickets' => I18n.t('views.helpers.roles.descriptions.tickets.delete_tickets'),
        'move_tickets' => I18n.t('views.helpers.roles.descriptions.tickets.move_tickets')
      },
      'meetings' => {
        'move_meetings' => I18n.t('views.helpers.roles.descriptions.meetings.move_meetings')
      },
      'users' => {
        'view_user_contact_details' => I18n.t('views.helpers.roles.descriptions.users.view_user_contact_details'),
        'view_user_full_name' => I18n.t('views.helpers.roles.descriptions.users.view_user_full_name')
      },
      'assistant' => {
        'use_assistant' => I18n.t('views.helpers.roles.descriptions.assistant.use_assistant')
      },
      'people' => {
        'view_people' => I18n.t('views.helpers.roles.descriptions.people.view_people'),
        'manage_people' => I18n.t('views.helpers.roles.descriptions.people.manage_people')
      },
      'glossary' => {
        'view_glossary' => I18n.t('views.helpers.roles.descriptions.glossary.view_glossary'),
        'manage_glossary' => I18n.t('views.helpers.roles.descriptions.glossary.manage_glossary')
      }
    }

    descriptions.dig(category, action) || I18n.t('views.helpers.roles.descriptions.none_available')
  end

  # Returns a user-friendly name for a permission category
  def category_name(category)
    names = {
      'accounts' => I18n.t('views.helpers.roles.categories.accounts'),
      'projects' => I18n.t('views.helpers.roles.categories.projects'),
      'tickets' => I18n.t('views.helpers.roles.categories.tickets'),
      'meetings' => I18n.t('views.helpers.roles.categories.meetings'),
      'users' => I18n.t('views.helpers.roles.categories.users'),
      'assistant' => I18n.t('views.helpers.roles.categories.assistant'),
      'people' => I18n.t('views.helpers.roles.categories.people'),
      'glossary' => I18n.t('views.helpers.roles.categories.glossary')
    }

    names[category] || category.humanize
  end
end
