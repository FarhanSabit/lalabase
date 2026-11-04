# frozen_string_literal: true

require 'rails_helper'

# What: the preview line under an item of a saved view, cut to 150 characters.
# Why: strip_tags returns HTML, and since Rails 8.1.4.1 it writes " and ' as
#   entities as well. truncate escapes what it returns, so a long preview showed
#   "&quot;" and "&#39;" as text, and "&amp;" and "&nbsp;" before that already.
RSpec.describe 'The preview line of an item in a saved view', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:folder) do
    create(:smart_folder, organisation: organisation, project: project, user: user, target_object_type: 'Note').tap do |view|
      group = create(:smart_folder_rule_group, smart_folder: view)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has', value: 'vorschau')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  # Without a description, so the preview comes from the content. cut: long enough
  # for truncate to cut it.
  def note_with(text, cut:)
    text += ' und mehr' * 20 if cut
    note = create(:note, project: project, organisation: organisation, creator: user, description: nil,
                         content: "<p>#{text}</p>")
    create(:tagging, tag: create(:tag, name: 'vorschau', organisation: organisation), taggable: note)
  end

  def folder_page
    get organisation_smart_folder_path(organisation, folder)
    expect(response).to have_http_status(:ok)
    Capybara.string(response.body)
  end

  it 'shows quotes, ampersands and no-break spaces of a cut text as they are written' do
    note_with(%q(Werkstatt&nbsp;"Nord" &amp; Kim's Plan), cut: true)

    expect(folder_page.text).to match(/Werkstatt[[:space:]]"Nord" & Kim's Plan und mehr/)
    expect(response.body).not_to include('&amp;quot;', '&amp;#39;', '&amp;amp;', '&amp;nbsp;')
  end

  # Uncut, because only a text that truncate leaves whole keeps a SafeBuffer: the
  # decoded text marked html_safe would show up here as markup.
  it 'shows markup that a text contains as text, not as markup' do
    note_with('Ein &lt;b&gt;fettes&lt;/b&gt; Wort', cut: false)

    html = folder_page
    expect(html.text).to include('Ein <b>fettes</b> Wort')
    expect(html).to have_no_css('b', text: 'fettes')
  end
end
