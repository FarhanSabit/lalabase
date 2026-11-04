# frozen_string_literal: true

require 'rails_helper'

# The glossary right in the role editor (K4a, plan §9): both actions appear
# with their descriptions in German and English, and an admin can grant them
# to a guest role (billable: false).
RSpec.describe 'Glossary right in the role editor', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:guest_role) do
    ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation, title: 'Kunde', billable: false) }
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, organisation: organisation, user: admin, role: create(:admin_role, organisation: organisation))
    end
    sign_in admin
  end

  %w[de en].each do |locale|
    it "lists the category with both rights and their descriptions (#{locale})" do
      get edit_organisation_role_path(organisation, guest_role, locale: locale)

      expect(response).to have_http_status(:ok)
      I18n.with_locale(locale) do
        expect(response.body).to include(ERB::Util.html_escape(I18n.t('views.helpers.roles.categories.glossary')))
        %w[view_glossary manage_glossary].each do |action|
          expect(response.body).to include("permissions[glossary][#{action}]")
          expect(response.body).to include(ERB::Util.html_escape(I18n.t("views.helpers.roles.descriptions.glossary.#{action}")))
        end
      end
    end
  end

  it 'grants both rights to a guest role' do
    patch organisation_role_path(organisation, guest_role),
          params: { role: { title: guest_role.title }, permissions: { glossary: { view_glossary: '1', manage_glossary: '1' } } }

    allowed = ActsAsTenant.with_tenant(organisation) do
      guest_role.permissions.reload.where(category: 'glossary', allowed: true).pluck(:action)
    end
    expect(allowed).to contain_exactly('view_glossary', 'manage_glossary')
  end
end
