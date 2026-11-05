# frozen_string_literal: true

require 'rails_helper'

# Correcting a misheard word in a meeting (K4b): the dialog (new), its count
# (count) and the correction (create). Rights in both directions: the meeting
# write opens all three (E2), anything less answers 403, a meeting of another
# project or organisation 404. What the dialog offers hangs on the glossary
# right: suggestions only with view_glossary, the box says "propose" without
# manage_glossary. Every negative claim stands next to proof that the dialog
# itself was rendered. Invented words and names only.
RSpec.describe 'Organisations::MeetingTermCorrections', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation, name: 'Projekt Ahorn') }
  let(:transcript) { "Anna: Wir testen Lalabeis heute.\nBen: Lalabeis kann viel.\nUnd Lalabeis-Konten auch." }
  let(:creator) { member_with(role_with) }
  let(:meeting) do
    create(:meeting, organisation: organisation, project: project, creator: creator, title: 'Abstimmung',
                     transcript: transcript, generated_summary: 'Lalabeis wurde vorgestellt.')
  end
  let!(:anna) { create(:meeting_participant, meeting: meeting, display_name: 'Anna Ananas') }
  let!(:ben) { create(:meeting_participant, meeting: meeting, display_name: 'Ben Birne') }
  let(:tc) { 'views.organisations.meetings.term_correction' }
  let(:frame) { { 'Turbo-Frame' => "meeting-term-correction-modal-#{meeting.id}" } }
  let(:stream) { { 'Accept' => 'text/vnd.turbo-stream.html' } }
  let(:modal_token) { SecureRandom.hex(8) }

  def role_with(*glossary_actions)
    role = create(:role, organisation: organisation)
    glossary_actions.each { |action| create(:permission, role: role, category: 'glossary', action: action, allowed: true) }
    role
  end

  def member_with(role)
    user = create(:user, first_name: 'Max', last_name: "Muster#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  def writer(*glossary_actions, access: :read_write)
    member_with(role_with(*glossary_actions)).tap do |user|
      create(:project_permission, user: user, project: project, meetings_access: access)
    end
  end

  def digest
    Digest::SHA256.hexdigest(meeting.reload.transcript.to_s)
  end

  # What the browser sends for the nth place of `text` in the text the page shows.
  def browser_mark(text = 'Lalabeis', nth: 1)
    html = ApplicationController.helpers.meeting_transcript_html(meeting.reload, meeting.meeting_participants.in_row_order.to_a)
    shown = Nokogiri::HTML5.fragment(html).text
    start = shown.to_enum(:scan, text).map { Regexp.last_match.begin(0) }.fetch(nth)
    { text: text, before: shown[[start - 40, 0].max...start], after: shown[start + text.length, 40], offset: start }
  end

  def new_path(mark: browser_mark, in_project: project, on: meeting)
    new_organisation_project_meeting_term_correction_path(organisation, in_project, on, mark: mark, digest: digest)
  end

  def count_path(heard: 'Lalabeis', mark: browser_mark, token: modal_token)
    count_organisation_project_meeting_term_correction_path(organisation, project, meeting, mark: mark, digest: digest,
                                                                                            modal_token: token,
                                                                                            term_correction: { heard: heard })
  end

  def correction_params(scope: 'everywhere', correct: 'Lalabase', heard: 'Lalabeis', speaker_id: ben.id, to_glossary: '1',
                        with_digest: digest)
    { modal_token: modal_token, mark: browser_mark, digest: with_digest, scope: scope,
      term_correction: { heard: heard, correct: correct, speaker_id: speaker_id, to_glossary: to_glossary } }
  end

  def post_correction(**options)
    post organisation_project_meeting_term_correction_path(organisation, project, meeting),
         params: correction_params(**options), headers: stream
  end

  def page_markup
    Capybara.string(response.body)
  end

  # The markup one stream of the answer carries (its <template>).
  def stream_markup(action, target)
    node = Nokogiri::HTML(response.body).at_css(%(turbo-stream[action="#{action}"][target="#{target}"]))
    raise "no #{action} stream for #{target} in the answer" unless node

    Capybara.string(node.at_css('template').inner_html)
  end

  describe 'the meeting page' do
    def show_meeting
      get organisation_project_meeting_path(organisation, project, meeting, frame: 'content'),
          headers: { 'Turbo-Frame' => Organisations::MeetingsController::DETAIL_FRAME_ID }
    end

    it 'offers the correction to a writer of the meeting, with the digest of the transcript it shows' do
      sign_in writer
      show_meeting

      expect(response).to have_http_status(:ok)
      section = page_markup.find("##{ActionView::RecordIdentifier.dom_id(meeting, :transcript)}")
      expect(section['data-controller']).to include('transcript-selection')
      expect(section['data-transcript-selection-digest-value']).to eq(digest)
      expect(page_markup).to have_css("turbo-frame#meeting-term-correction-modal-#{meeting.id}")
      expect(page_markup).to have_css("#meeting-term-correction-trigger-#{meeting.id}", visible: :all)
    end

    it 'offers nothing to a reader of the meeting' do
      sign_in writer(access: :read_only)
      show_meeting

      expect(response.body).to include('Lalabeis kann viel')
      expect(response.body).not_to include('transcript-selection')
      expect(response.body).not_to include("meeting-term-correction-modal-#{meeting.id}")
    end
  end

  describe 'the dialog' do
    it 'opens in its frame with the heard form, the speaker of the line and the count' do
      sign_in writer
      get new_path, headers: frame

      expect(response).to have_http_status(:ok)
      dialog = page_markup.find("turbo-frame#meeting-term-correction-modal-#{meeting.id}")
      expect(dialog).to have_field('term_correction[heard]', with: 'Lalabeis')
      expect(dialog).to have_select('term_correction[speaker_id]', selected: 'Ben Birne')
      expect(dialog).to have_text(I18n.t("#{tc}.count.found_by_speaker", count: 3, speaker_count: 2, speaker: 'Ben Birne'))
      expect(dialog).to have_button(I18n.t("#{tc}.everywhere", count: 3))
      expect(dialog).to have_button(I18n.t("#{tc}.here"))
      expect(dialog).to have_css("input[name='digest'][value='#{digest}']", visible: :all)
    end

    it 'names the box "propose" without manage_glossary and "take over" with it' do
      sign_in writer('view_glossary')
      get new_path, headers: frame
      expect(page_markup).to have_field(I18n.t("#{tc}.to_glossary_propose"), checked: true)
      expect(page_markup).not_to have_field(I18n.t("#{tc}.to_glossary_confirm"))

      sign_in writer('manage_glossary')
      get new_path, headers: frame
      expect(page_markup).to have_field(I18n.t("#{tc}.to_glossary_confirm"), checked: true)
    end

    it 'suggests terms of the glossary only with view_glossary' do
      create(:glossary_term, organisation: organisation, term: 'Lalabase')
      create(:glossary_term, :rejected, organisation: organisation, term: 'Verworfenes Wort')

      sign_in writer('view_glossary')
      get new_path, headers: frame
      expect(page_markup).to have_css('datalist option[value="Lalabase"]', visible: :all)
      expect(response.body).not_to include('Verworfenes Wort')

      sign_in writer
      get new_path, headers: frame
      expect(page_markup).to have_field('term_correction[correct]')
      expect(response.body).not_to include('<datalist')
      expect(response.body).not_to include('Lalabase')
    end

    it 'says why, and offers no form, for a mark it cannot place' do
      sign_in writer
      get new_path(mark: browser_mark('Lalabei', nth: 0)), headers: frame

      expect(response).to have_http_status(:ok)
      expect(page_markup).to have_text(I18n.t("#{tc}.mark_errors.not_a_word"))
      expect(page_markup).not_to have_field('term_correction[correct]')
    end

    it 'counts again for a transcript changed since the page was drawn, and says so' do
      sign_in writer
      mark = browser_mark
      meeting.update_columns(transcript: "#{transcript}\nAnna: Lalabeis zum Schluss.")

      get new_organisation_project_meeting_term_correction_path(organisation, project, meeting, mark: mark,
                                                                                                digest: Digest::SHA256.hexdigest(transcript)),
          headers: frame

      expect(page_markup).to have_text(I18n.t("#{tc}.recounted"))
      expect(page_markup).to have_button(I18n.t("#{tc}.everywhere", count: 4))
      expect(page_markup).to have_css("input[name='digest'][value='#{digest}']", visible: :all)
    end
  end

  # Prosopite watches every example: the dialog reads the participants, the
  # glossary suggestions and the glossary rights once, however many there are.
  describe 'queries' do
    before do
      Prosopite.pause do
        4.times do |index|
          create(:meeting_participant, meeting: meeting, display_name: "Gast Nummer#{index}",
                                       person: create(:person, organisation: organisation))
          create(:glossary_term, organisation: organisation, term: "Begriff #{index}")
        end
      end
    end

    it 'opens the dialog with many participants and terms without an N+1' do
      sign_in writer('manage_glossary')
      get new_path, headers: frame

      expect(response).to have_http_status(:ok)
      expect(page_markup).to have_css('select[name="term_correction[speaker_id]"] option', count: 7)
      expect(page_markup).to have_css('datalist option', count: 4, visible: :all)
    end

    it 'corrects in a meeting with many participants and terms without an N+1' do
      sign_in writer('manage_glossary')
      post_correction

      expect(response).to have_http_status(:ok)
      expect(TermCorrection.count).to eq(1)
    end
  end

  describe 'the count' do
    it 'counts the heard form as typed, in its own frame' do
      sign_in writer
      get count_path(heard: 'Lalabeis'), headers: { 'Turbo-Frame' => "meeting-term-correction-count-#{meeting.id}-#{modal_token}" }

      expect(response).to have_http_status(:ok)
      expect(page_markup).to have_css("turbo-frame#meeting-term-correction-count-#{meeting.id}-#{modal_token}")
      expect(page_markup).to have_button(I18n.t("#{tc}.everywhere", count: 3))
    end

    it 'offers no button where the changed form does not stand at the mark' do
      sign_in writer
      get count_path(heard: 'Konten')

      expect(page_markup).to have_text(I18n.t("#{tc}.count.not_at_mark"))
      expect(page_markup).not_to have_button(I18n.t("#{tc}.here"))
    end
  end

  describe 'correcting' do
    it 'replaces everywhere, redraws the transcript, closes this opening and says how often' do
      sign_in writer('manage_glossary')
      post_correction

      expect(response).to have_http_status(:ok)
      expect(meeting.reload.transcript).to eq("Anna: Wir testen Lalabase heute.\nBen: Lalabase kann viel.\nUnd Lalabase-Konten auch.")
      expect(stream_markup('replace', ActionView::RecordIdentifier.dom_id(meeting, :transcript))).to have_text('Lalabase kann viel')
      expect(response.body).to include(%(<turbo-stream action="remove" target="meeting-term-correction-modal-#{meeting.id}-#{modal_token}">))
      expect(stream_markup('prepend', 'flash')).to have_text(I18n.t("#{tc}.flash.replaced", count: 3))
      expect(stream_markup('prepend', 'flash')).to have_text(I18n.t("#{tc}.flash.confirmed"))
      expect(stream_markup('replace', "#{ActionView::RecordIdentifier.dom_id(meeting)}_summary_section"))
        .to have_text('Lalabase wurde vorgestellt.')
    end

    it 'proposes for the glossary without manage_glossary, and says so' do
      sign_in writer
      post_correction(scope: 'here')

      expect(meeting.reload.transcript).to include('Ben: Lalabase kann viel.')
      expect(TermCorrection.last).to be_proposed
      expect(stream_markup('prepend', 'flash')).to have_text(I18n.t("#{tc}.flash.replaced", count: 1))
      expect(stream_markup('prepend', 'flash')).to have_text(I18n.t("#{tc}.flash.proposed"))
    end

    it 'writes the transcript only when the box is off' do
      sign_in writer('manage_glossary')
      post_correction(to_glossary: '0')

      expect(meeting.reload.transcript).to include('Lalabase')
      expect(TermCorrection.count).to eq(0)
    end

    it 'shows the dialog again, counted anew, for a transcript changed since it counted, and writes nothing' do
      sign_in writer('manage_glossary')
      old_digest = digest
      meeting.update_columns(transcript: "#{transcript}\nAnna: Lalabeis zum Schluss.")

      post_correction(with_digest: old_digest)

      expect(response).to have_http_status(:unprocessable_content)
      instance = stream_markup('replace', "meeting-term-correction-modal-#{meeting.id}-#{modal_token}")
      expect(instance).to have_text(I18n.t("#{tc}.recounted"))
      expect(instance).to have_button(I18n.t("#{tc}.everywhere", count: 4))
      expect(meeting.reload.transcript).not_to include('Lalabase')
      expect(TermCorrection.count).to eq(0)
    end

    it 'shows the dialog again with the reason for a refused correction' do
      sign_in writer('manage_glossary')
      post_correction(correct: '  ')

      expect(response).to have_http_status(:unprocessable_content)
      instance = stream_markup('replace', "meeting-term-correction-modal-#{meeting.id}-#{modal_token}")
      expect(instance).to have_text(I18n.t('services.actors.correct_meeting_term.correct_blank'))
      expect(meeting.reload.transcript).to eq(transcript)
    end
  end

  describe 'who may not correct' do
    def requests
      {
        'the dialog' => -> { get new_path, headers: frame },
        'the count' => -> { get count_path },
        'the correction' => -> { post_correction }
      }
    end

    ['the dialog', 'the count', 'the correction'].each do |name|
      it "answers 403 to a reader of the meeting on #{name}" do
        sign_in writer('manage_glossary', access: :read_only)
        instance_exec(&requests.fetch(name))

        expect(response).to have_http_status(:forbidden)
        expect(meeting.reload.transcript).to eq(transcript)
      end

      it "answers 403 to a member without access to the project on #{name}" do
        sign_in member_with(role_with('manage_glossary'))
        instance_exec(&requests.fetch(name))

        expect(response).to have_http_status(:forbidden)
        expect(meeting.reload.transcript).to eq(transcript)
      end
    end

    it 'answers 403 in an archived project to a writer' do
      user = writer('manage_glossary')
      project.update_columns(archived_at: Time.current)
      sign_in user

      post_correction
      expect(response).to have_http_status(:forbidden)
      get new_path, headers: frame
      expect(response).to have_http_status(:forbidden)
      expect(meeting.reload.transcript).to eq(transcript)
    end

    it 'finds no meeting of another project' do
      other_project = create(:project, organisation: organisation)
      user = writer('manage_glossary')
      create(:project_permission, user: user, project: other_project, meetings_access: :read_write)
      sign_in user

      get new_organisation_project_meeting_term_correction_path(organisation, other_project, meeting, mark: browser_mark,
                                                                                                      digest: digest),
          headers: frame
      expect(response).to have_http_status(:not_found)
      post organisation_project_meeting_term_correction_path(organisation, other_project, meeting),
           params: correction_params, headers: stream
      expect(response).to have_http_status(:not_found)
      expect(meeting.reload.transcript).to eq(transcript)
    end

    # A forged id: the meeting of another organisation under the own address.
    it 'answers 404 for a meeting of another organisation' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:meeting, organisation: other, project: create(:project, organisation: other), creator: creator,
                         transcript: transcript)
      end
      sign_in writer('manage_glossary')

      get new_organisation_project_meeting_term_correction_path(organisation, project, foreign.id, mark: browser_mark,
                                                                                                   digest: digest),
          headers: frame
      expect(response).to have_http_status(:not_found)
      post organisation_project_meeting_term_correction_path(organisation, project, foreign.id),
           params: correction_params, headers: stream
      expect(response).to have_http_status(:not_found)
      expect(ActsAsTenant.without_tenant { foreign.reload.transcript }).to eq(transcript)
    end

    it 'refuses a member of another organisation' do
      stranger_org = create(:organisation)
      stranger = ActsAsTenant.with_tenant(stranger_org) do
        user = create(:user)
        create(:membership, user: user, organisation: stranger_org,
                            role: create(:role, organisation: stranger_org, title: Role::ACCOUNT_ADMIN_TITLE), active: true)
        user
      end
      # One sign-in per request: a 404 of the exceptions app writes no session.
      sign_in stranger
      get new_path, headers: frame
      expect(response.status).to be_in([302, 404])
      expect(response.location.to_s).not_to include(new_user_session_path)
      sign_in stranger
      post_correction
      expect(response.status).to be_in([302, 404])
      expect(response.location.to_s).not_to include(new_user_session_path)
      expect(meeting.reload.transcript).to eq(transcript)
      expect(TermCorrection.count).to eq(0)
    end
  end
end
