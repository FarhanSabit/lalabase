# frozen_string_literal: true

require 'rails_helper'

# In-app per-org persona management. Mirrors organisation_settings_spec's
# admin/member/anonymous matrix and adds the per-org invariants: system:false is
# forced, and neither the global pool nor another org's personas are reachable.
RSpec.describe 'Organisations::PromptPersonas', type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:admin_role)  { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin)  { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
  end
  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) { create(:membership, user: member, organisation: organisation, role: member_role, active: true) }
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:global) { create(:prompt_persona, organisation: nil, key: 'overview', system: true) }

  describe 'GET index' do
    it 'shows own rows as editable and globals as read-only templates (partition pinned)' do
      own = create(:prompt_persona, organisation: organisation, key: 'house_style')
      global
      sign_in admin

      get organisation_prompt_personas_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('house_style') # own, editable
      expect(response.body).to include('overview')    # global, read-only template
      expect(response.body).not_to include('translation missing')
      # G6b: the editable-own vs read-only-global split is the whole point of this
      # screen. Own rows get an edit link; globals do not. Swapping the index's
      # own/global select predicates turns this red.
      expect(response.body).to include(edit_organisation_prompt_persona_path(organisation, own))
      expect(response.body).not_to include(edit_organisation_prompt_persona_path(organisation, global))
    end

    it 'denies a non-admin member (Pundit → redirect to root)' do
      sign_in member
      get organisation_prompt_personas_path(organisation)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
    end

    it 'redirects an unauthenticated visitor to sign in' do
      get organisation_prompt_personas_path(organisation)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'POST create' do
    let(:valid_params) do
      { prompt_persona: { key: 'house_style', position: 2,
                          labels: { de: 'Hausstil', en: 'House style' },
                          prompt_fragments: { de: 'DE-Intent', en: 'EN-Intent' } } }
    end

    it 'creates a persona owned by the current org (always active, never system)' do
      sign_in admin

      expect { post organisation_prompt_personas_path(organisation), params: valid_params }
        .to change { organisation.prompt_personas.count }.by(1)

      persona = organisation.prompt_personas.find_by(key: 'house_style')
      expect(persona.organisation_id).to eq(organisation.id)
      expect(persona.system?).to be(false)
      expect(persona.active?).to be(true)
    end

    it 'persists BOTH supported languages and filters unsupported keys (closed permit list)' do
      sign_in admin

      post organisation_prompt_personas_path(organisation), params: { prompt_persona: {
        key: 'multilang',
        labels: { de: 'DE', en: 'EN', fr: 'FR-leak' },
        prompt_fragments: { de: 'DE', en: 'EN', fr: 'FR-leak' }
      } }

      persona = organisation.prompt_personas.find_by(key: 'multilang')
      expect(persona.labels.keys).to match_array(%w[de en]) # G2 shrink + G3 open-hash
      expect(persona.labels).not_to have_key('fr')
    end

    it 'FORCES system:false + own org even when params inject them' do
      sign_in admin

      post organisation_prompt_personas_path(organisation), params: {
        prompt_persona: { key: 'sneaky', labels: { de: 'x' }, prompt_fragments: { de: 'y' },
                          system: '1', organisation_id: other_organisation.id }
      }

      persona = PromptPersona.find_by(key: 'sneaky')
      expect(persona.organisation_id).to eq(organisation.id) # not the injected org
      expect(persona.system?).to be(false)                   # injected system flag ignored
    end

    # The neutral persona (PromptPersona::NEUTRAL_KEY) is the one row that may go
    # out with its fragment empty, and a form submits empty textareas as
    # {"de"=>"", "en"=>""}, never as {}. That is the shape the model's second
    # exception exists for; here it is proven through strong params and the
    # controller rather than on a built record.
    it 'accepts a neutral override whose fragment fields were left blank in the form' do
      sign_in admin

      expect do
        post organisation_prompt_personas_path(organisation), params: { prompt_persona: {
          key: PromptPersona::NEUTRAL_KEY, position: 9,
          labels: { de: 'Neutral', en: 'Neutral' }, prompt_fragments: { de: '', en: '' }
        } }
      end.to change { organisation.prompt_personas.count }.by(1)

      expect(response).to redirect_to(organisation_prompt_personas_path(organisation))
      persona = organisation.prompt_personas.find_by!(key: PromptPersona::NEUTRAL_KEY)
      expect(persona.prompt_fragment('de')).to be_nil
      expect(persona.label('de')).to eq('Neutral')
    end

    it 're-renders 422 on invalid input' do
      sign_in admin
      post organisation_prompt_personas_path(organisation), params: { prompt_persona: { key: '', labels: {}, prompt_fragments: {} } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'denies a non-admin member' do
      sign_in member
      expect { post organisation_prompt_personas_path(organisation), params: valid_params }
        .not_to change(PromptPersona, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe 'GET new with ?from= (override flow)' do
    it 'prefills key, label AND fragment from a global template' do
      create(:prompt_persona, organisation: nil, key: 'overview', position: 4,
                              labels: { de: 'Überblick', en: 'Overview' },
                              prompt_fragments: { de: 'DE-Frag', en: 'EN-Frag' })
      sign_in admin

      get new_organisation_prompt_persona_path(organisation, from: 'overview')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('overview')  # prefilled key
      expect(response.body).to include('Überblick') # G5a: prefilled label, not just the key
      expect(response.body).to include('DE-Frag')   # G5a: prefilled fragment
      expect(response.body).not_to include('translation missing')
    end

    it 'does NOT prefill from a non-global key — no cross-scope content leak' do
      create(:prompt_persona, organisation: other_organisation, key: 'foreign_secret',
                              labels: { de: 'GEHEIM', en: 'SECRET' })
      sign_in admin

      get new_organisation_prompt_persona_path(organisation, from: 'foreign_secret')

      expect(response).to have_http_status(:ok)
      # G5b: build_persona's find_by(organisation_id: nil, ...) must scope to GLOBAL
      # rows; dropping that filter would leak another org's content into the form.
      expect(response.body).not_to include('GEHEIM')
    end
  end

  describe 'GET edit (own persona form renders with all keys present)' do
    it 'renders without missing translations' do
      persona = create(:prompt_persona, organisation: organisation, key: 'house_style')
      sign_in admin
      get edit_organisation_prompt_persona_path(organisation, persona)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'PATCH update' do
    it 'updates an own persona' do
      persona = create(:prompt_persona, organisation: organisation, key: 'house_style', position: 1)
      sign_in admin

      patch organisation_prompt_persona_path(organisation, persona), params: {
        prompt_persona: { position: 5, labels: { de: 'Neu', en: 'New' }, prompt_fragments: { de: 'a', en: 'b' } }
      }

      expect(persona.reload.position).to eq(5)
      expect(persona.label('de')).to eq('Neu')
    end
  end

  describe 'isolation: global + cross-org personas are unreachable in-app' do
    it '404s when editing a GLOBAL persona (operator territory)' do
      sign_in admin
      get edit_organisation_prompt_persona_path(organisation, global)
      expect(response).to have_http_status(:not_found)
    end

    it '404s when editing ANOTHER org’s persona (org-scoped lookup)' do
      foreign = create(:prompt_persona, organisation: other_organisation, key: 'foreign')
      sign_in admin
      get edit_organisation_prompt_persona_path(organisation, foreign)
      expect(response).to have_http_status(:not_found)
    end

    it '404s when deleting a GLOBAL persona, leaving it intact' do
      global
      sign_in admin
      expect { delete organisation_prompt_persona_path(organisation, global) }.not_to change(PromptPersona, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE destroy' do
    it 'destroys an own persona' do
      persona = create(:prompt_persona, organisation: organisation, key: 'house_style')
      sign_in admin
      expect { delete organisation_prompt_persona_path(organisation, persona) }
        .to change { organisation.prompt_personas.count }.by(-1)
    end
  end

  # The list is the Chat-Personas tab of the AI section, the two forms are pages below
  # it (doc/verwaltung_seitennavigation_plan.md §5, S3): the head names the section on
  # all three. The list's help stands in the head; the forms mark the tab as their
  # parent and name themselves in the crumb, which leads back to the list.
  describe 'the head of the AI section' do
    let(:personas) { I18n.t('views.organisations.ai_overview.pages.personas') }
    let(:help_label) { I18n.t('components.contextual_help.label') }

    before { sign_in admin }

    def page_doc(path)
      get path
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    def section_title(doc) = doc.css('main h1').map { |h1| h1.text.squish }

    def marked_tabs(doc)
      doc.css('main nav:not([data-section-crumb]) [aria-current]').map { |tab| [tab.text.squish, tab['aria-current']] }
    end

    def expect_below_the_list(doc, page)
      expect(section_title(doc)).to eq([I18n.t('settings.ai')])
      expect(marked_tabs(doc)).to eq([[personas, 'true']])
      back = doc.at_css('main [data-section-crumb] a')
      expect(back['href']).to eq(organisation_prompt_personas_path(organisation))
      expect(back.text.delete('‹').squish).to eq(personas)
      expect(doc.css('main [aria-current="page"]').map { |item| item.text.squish }).to eq([page])
      expect(doc.css('main i.bi-arrow-left')).to be_empty
    end

    it 'names the section on the list, marks its tab as the page and puts the help into the head' do
      doc = page_doc(organisation_prompt_personas_path(organisation))

      expect(section_title(doc)).to eq([I18n.t('settings.ai')])
      expect(marked_tabs(doc)).to eq([[personas, 'page']])
      head_row = doc.at_css('main h1').ancestors('.flex.flex-wrap').first
      expect(head_row.at_css("[title='#{help_label}']")).to be_present
      expect(doc.css("main [title='#{help_label}']").size).to eq(1)
    end

    it 'puts the new form below the tab' do
      expect_below_the_list(page_doc(new_organisation_prompt_persona_path(organisation)),
                            I18n.t('views.organisations.prompt_personas.new.title'))
    end

    # The stored key, not the one just typed: after a refused save the form shows the
    # attempt, the crumb still names the persona being edited.
    it 'puts the edit form below the tab and names the stored persona, also after a refused save' do
      persona = create(:prompt_persona, organisation: organisation, key: 'house_style')
      title = I18n.t('views.organisations.prompt_personas.edit.title', key: 'house_style')

      expect_below_the_list(page_doc(edit_organisation_prompt_persona_path(organisation, persona)), title)

      patch organisation_prompt_persona_path(organisation, persona), params: { prompt_persona: { key: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect_below_the_list(Nokogiri::HTML(response.body), title)
    end
  end
end
