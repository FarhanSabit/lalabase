# frozen_string_literal: true

require 'rails_helper'

# What: Notification.search finds what an inbox row shows: the title of what
#       it is about (ticket, meeting), the project, the name of who did it.
# Why:  until 2026-11-10 it searched the payload's JSON text, which holds an
#       activity id, the action's name and its parameters: the title in the row
#       was not found, while "post" found every comment (action "post_added").
#       The search answers while typing since then, which shows that at once.
#       Never the actor's address: it may be a login address hidden from others.
RSpec.describe Notification, '.search' do
  let(:organisation) { create(:organisation) }
  let(:recipient) { create(:user) }
  let(:actor) { create(:user, first_name: 'Daniel', last_name: 'Beispiel', email: 'versteckt@example.com') }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Konfigurator') } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def notification_about(notifiable, actor: nil, payload: {})
    create(:notification, recipient: recipient, organisation: organisation, project: project,
                          notifiable: notifiable, actor: actor, channel: 'in_app', state: :delivered,
                          payload: payload)
  end

  let(:ticket) { create(:ticket, project: project, title: 'Exportfehler im Bericht') }
  let(:other_ticket) { create(:ticket, project: project, title: 'Startseite') }
  let!(:about_ticket) { notification_about(ticket, actor: actor, payload: { action: 'post_added' }) }
  let!(:about_other) { notification_about(other_ticket, payload: { action: 'post_added' }) }

  it 'finds the title of the ticket, in any case' do
    expect(described_class.search('exportFEHLER')).to contain_exactly(about_ticket)
  end

  it 'finds the title of a meeting' do
    meeting = create(:meeting, project: project, title: 'Quartalsplanung')
    about_meeting = notification_about(meeting)

    expect(described_class.search('quartal')).to contain_exactly(about_meeting)
  end

  it 'finds the project' do
    expect(described_class.search('konfig')).to contain_exactly(about_ticket, about_other)
  end

  it "finds the actor's whole name" do
    expect(described_class.search('Daniel Beispiel')).to contain_exactly(about_ticket)
  end

  it "finds neither the actor's address nor the payload's words" do
    expect(described_class.search('versteckt')).to be_empty
    expect(described_class.search('post_added')).to be_empty
  end

  it 'takes % and _ as letters, not as wildcards' do
    expect(described_class.search('%')).to be_empty
    expect(described_class.search('_')).to be_empty
  end

  it 'ignores a blank search' do
    expect(described_class.search('  ')).to contain_exactly(about_ticket, about_other)
  end
end
