# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Membership management', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:member) { create(:user, first_name: 'Anna', last_name: 'Berg') }
  let(:role) { create(:role, organisation: organisation, title: 'Standard-Benutzer') }
  let(:admin_membership) { create(:membership, organisation: organisation, user: admin, role: create(:admin_role, organisation: organisation)) }
  let(:membership) { create(:membership, organisation: organisation, user: member, role: role) }
  let(:invitation) { create(:invitation, organisation: organisation, inviter: admin, email: 'invitee@example.com', sent_at: 1.day.ago) }

  before do
    @previous_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
    admin_membership
    membership
    invitation
    sign_in admin
  end

  after do
    ActsAsTenant.current_tenant = nil
    ActiveJob::Base.queue_adapter = @previous_queue_adapter
  end

  def workspace
    Nokogiri::HTML(response.body).at_css('#members_workspace')
  end

  it 'renders compact rows, local dates and a copy action without embedding the token anywhere' do
    get organisation_memberships_path(organisation)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(invitation.token, 'tr[data-href]')
    expect(workspace.css('thead th').map(&:text).join).not_to include('Aktiv')
    expect(workspace.at_css("#membership_#{membership.id} time").text).to eq(I18n.l(membership.created_at.to_date))
    # The invite is the head's "+" since 2026-11-11, outside the workspace frame.
    invite = Nokogiri::HTML(response.body).css("a[href='#{new_organisation_invitation_path(organisation)}'][title='#{I18n.t('member_management.invite')}']")
    expect(invite.size).to eq(1)
    expect(workspace.at_css("#membership_#{admin_membership.id}").text).to include('du')
    expect(workspace.at_css("#membership_#{admin_membership.id}").text).not_to include('Aus der Organisation entfernen')
    expect(workspace.at_css("#membership_#{membership.id}").text).to include('Aus der Organisation entfernen')
    expect(workspace.css('input[type="search"]')).to be_empty
  end

  it 'shows a read-only list without invitation controls or role dropdowns for non-admins' do
    sign_in member
    get organisation_memberships_path(organisation)

    expect(response).to have_http_status(:ok)
    expect(workspace.css('select, .more-menu, #pending-invitations')).to be_empty
    expect(Nokogiri::HTML(response.body).css("a[href='#{new_organisation_invitation_path(organisation)}']")).to be_empty
    expect(response.body).not_to include(invitation.email, invitation.token)
  end

  it 'opens the selected membership beside the list and redirects legacy edit links there' do
    get edit_organisation_membership_path(organisation, membership)
    expect(response).to redirect_to(organisation_memberships_path(organisation, membership_id: membership.id))
    follow_redirect!

    expect(workspace.css('.members-panel').size).to eq(1)
    expect(workspace.at_css('.members-row--selected')['id']).to eq("membership_#{membership.id}")
    expect(workspace.at_css('.members-panel').text).to include('Änderungen greifen sofort.', member.email)
    expect(workspace.at_css('.members-panel').text).not_to include('Speichern', 'Abbrechen')
  end

  it 'updates just the selected field and preserves the open panel and filters' do
    patch organisation_membership_path(organisation, membership), params: { membership: { active: false }, membership_id: membership.id, q: 'Anna', sort: 'role' }

    expect(response).to have_http_status(:see_other)
    expect(membership.reload).not_to be_active
    expect(membership.role_id).to eq(role.id)
    follow_redirect!
    expect(workspace.at_css('.members-panel').text).to include('Anna')
    expect(workspace.at_css('.members-row--selected').text).to include('gesperrt')
  end

  it 'updates database roles including memberships without an old role' do
    membership.update_column(:role_id, nil)
    patch organisation_membership_path(organisation, membership), params: { membership: { role_id: role.id } }
    expect(response).to have_http_status(:see_other)
    expect(membership.reload.role_id).to eq(role.id)
  end

  it 'rejects foreign organisation roles without changing the membership' do
    foreign_role = ActsAsTenant.without_tenant { create(:role, organisation: create(:organisation)) }
    patch organisation_membership_path(organisation, membership), params: { membership: { role_id: foreign_role.id } }
    expect(response).to have_http_status(:not_found)
    expect(membership.reload.role_id).to eq(role.id)
  end

  it 'renders validation failures in the lane with the role options still available' do
    patch organisation_membership_path(organisation, membership), params: { membership: { active: nil }, membership_id: membership.id }
    expect(response).to have_http_status(:unprocessable_content)
    expect(workspace.at_css('.members-panel [role="alert"]')).to be_present
    expect(workspace.css('.members-panel select option').map(&:text)).to include(role.title)
    expect(membership.reload).to be_active
  end

  it 'denies non-admin direct edits and self-removal' do
    delete organisation_membership_path(organisation, admin_membership), as: :json
    expect(response).to redirect_to(root_path)
    expect(admin_membership.reload).to be_persisted
    sign_in member
    patch organisation_membership_path(organisation, membership), params: { membership: { role_id: admin_membership.role_id } }, as: :json
    expect(response).to redirect_to(root_path)
    get organisation_memberships_path(organisation, membership_id: membership.id), as: :json
    expect(response).to redirect_to(root_path)
  end

  it 'searches names and emails and sorts by name, role and date' do
    get organisation_memberships_path(organisation), params: { q: member.email, sort: 'since', direction: 'desc' }
    expect(workspace.css('tbody .members-row').map { |row| row['id'] }).to eq(["membership_#{membership.id}"])
    get organisation_memberships_path(organisation), params: { sort: 'role' }
    expect(workspace.css('tbody .members-row').first['id']).to eq("membership_#{admin_membership.id}")
    get organisation_memberships_path(organisation), params: { sort: 'name' }
    names = workspace.css('tbody .members-name').map(&:text)
    expect(names).to eq(names.sort_by(&:downcase))
  end

  it 'offers search starting at twelve visible members' do
    9.times { create(:membership, organisation: organisation, role: role, user: create(:user)) }
    get organisation_memberships_path(organisation)
    expect(workspace.css('input[type="search"]')).to be_empty
    ActsAsTenant.with_tenant(organisation) { create(:membership, organisation: organisation, role: role, user: create(:user)) }
    get organisation_memberships_path(organisation)
    expect(workspace.css('input[type="search"]').size).to eq(1)
  end

  it 'cannot copy, resend or edit records from another organisation through this organisation' do
    foreign_invitation, foreign_membership = ActsAsTenant.without_tenant do
      foreign_org = create(:organisation)
      [create(:invitation, organisation: foreign_org), create(:membership, organisation: foreign_org)]
    end
    get copy_link_organisation_invitation_path(organisation, foreign_invitation), as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(foreign_invitation.token)
    sign_in admin # request specs lose the session cookie after a handled 404
    expect { post resend_organisation_invitation_path(organisation, foreign_invitation), as: :json }.not_to have_enqueued_mail(InvitationMailer, :invite_email)
    expect(response).to have_http_status(:not_found)
    sign_in admin
    patch organisation_membership_path(organisation, foreign_membership), params: { membership: { active: false } }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(foreign_membership.reload).to be_active
  end

  it 'only returns the invitation URL on an authorized, non-cacheable explicit request' do
    get copy_link_organisation_invitation_path(organisation, invitation), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['url']).to include(invitation.token)
    expect(response.headers['Cache-Control']).to include('no-store')
    sign_in member
    get copy_link_organisation_invitation_path(organisation, invitation), as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(invitation.token)
  end

  it 'resends pending invitations, refreshes validity and enqueues exactly one email' do
    invitation.update!(sent_at: 1.week.ago)
    expect do
      post resend_organisation_invitation_path(organisation, invitation)
    end.to have_enqueued_mail(InvitationMailer, :invite_email).once
    expect(ActsAsTenant.with_tenant(organisation) { invitation.reload.sent_at }).to be_within(5.seconds).of(Time.current)
    expect(response).to redirect_to(organisation_memberships_path(organisation))
  end

  it 'does not resend accepted invitations or allow non-admin resends' do
    invitation.update!(accepted_at: Time.current)
    expect { post resend_organisation_invitation_path(organisation, invitation), as: :json }.not_to have_enqueued_mail(InvitationMailer, :invite_email)
    expect(response).to redirect_to(root_path)
    get copy_link_organisation_invitation_path(organisation, invitation), as: :json
    expect(response).to redirect_to(root_path)
    sign_in member
    expect { post resend_organisation_invitation_path(organisation, invitation) }.not_to have_enqueued_mail(InvitationMailer, :invite_email)
    expect(response).to have_http_status(:not_found)
  end
end
