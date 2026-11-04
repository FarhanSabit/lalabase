# frozen_string_literal: true

require 'rails_helper'

# The core security property of the export: CROSS-ORG AND CROSS-USER ISOLATION.
# The builder iterates the user's memberships (all of them, incl. inactive —
# Art. 15) inside with_tenant, owner-scoped on top. It must never contain
# another user's rows, never an org without a membership row (D9 role model),
# and never credential material.
RSpec.describe UserDataExports::Builder,
               legal_identity: { privacy_page_url: 'https://public.example/datenschutz' } do
  let(:user) { create(:user, language_preference: 'de') }
  let(:other_user) { create(:user) }
  # Org names are unique app-wide, but DIFFERENT names can parameterize to the
  # SAME folder slug — the id suffix must still keep the folders apart.
  let(:org_a) { create(:organisation, name: 'Agentur Alpha') }
  let(:org_b) { create(:organisation, name: 'Agentur-Alpha!') }
  let(:foreign_org) { create(:organisation, name: 'Fremd GmbH') }

  before do
    # Membership factory builds a Role, which is acts_as_tenant — create each
    # membership inside its org's tenant.
    ActsAsTenant.with_tenant(org_a) { create(:membership, user: user, organisation: org_a) }
    ActsAsTenant.with_tenant(org_b) { create(:membership, user: user, organisation: org_b, active: false) }
    ActsAsTenant.with_tenant(org_a) { create(:membership, user: other_user, organisation: org_a) }

    ActsAsTenant.with_tenant(org_a) do
      create(:personal_task, user: user, organisation: org_a, title: 'Meine Aufgabe A')
      create(:personal_task, user: other_user, organisation: org_a, title: 'Fremde Aufgabe')
    end
    ActsAsTenant.with_tenant(org_b) do
      create(:personal_task, user: user, organisation: org_b, title: 'Aufgabe B inaktiv')
    end
    ActsAsTenant.with_tenant(foreign_org) do
      create(:personal_task, user: other_user, organisation: foreign_org, title: 'Ganz fremde Aufgabe')
    end
  end

  subject(:files) { described_class.new(user).files }

  def org_folders
    files.keys.select { |k| k.start_with?('organisations/') }
         .map { |k| k.split('/')[1] }.uniq
  end

  # Mirrors Builder#org_folder_name — kept in sync via the attribution test
  # below (wrong naming ⇒ the file lookup misses ⇒ red).
  def expected_folder(org)
    "#{org.name.parameterize}-#{org.id.to_s.first(8)}"
  end

  it 'contains README, the global files and preferences' do
    expect(files.keys).to include('README.txt', 'account.json', 'memberships.json',
                                  'security_history.json', 'api_tokens.json',
                                  'notification_preferences.json', 'preferences.json')
  end

  it 'exports account data without any credential material' do
    expect(files['account.json']).to include(user.email)
    expect(files['account.json']).not_to include('encrypted_password', 'reset_password_token')
  end

  # The README is rendered in a job with no request, so it must read the
  # configured absolute privacy URL directly.
  it 'exports which email the member shows and the contact address' do
    user.update!(email_visibility: 'contact', contact_email: 'kontakt@example.com')
    account = JSON.parse(described_class.new(user).files['account.json'])
    row = account.is_a?(Array) ? account.first : account

    expect(row).to include('email_visibility' => 'contact', 'contact_email' => 'kontakt@example.com')
  end

  it 'uses the configured privacy URL, never a renderer default' do
    expect(files['README.txt']).to include('https://public.example/datenschutz')
    expect(files['README.txt']).not_to include('example.org')
  end

  it 'creates one folder per membership org — INCLUDING inactive memberships' do
    expect(org_folders.size).to eq(2)
    expect(files.keys.join).not_to include('fremd-gmbh')
  end

  it 'keeps two same-named orgs in distinct folders (id suffix)' do
    expect(org_folders).to all(start_with('agentur-alpha-'))
    expect(org_folders.uniq.size).to eq(2)
  end

  # Strict per-folder attribution: a builder that dumps every org's data into
  # every folder would still pass a "contains somewhere" check — each task
  # must appear in EXACTLY its own org's file.
  it 'attributes each org\'s tasks to exactly its own folder' do
    file_a = files["organisations/#{expected_folder(org_a)}/personal_tasks.json"]
    file_b = files["organisations/#{expected_folder(org_b)}/personal_tasks.json"]

    expect(file_a).to include('Meine Aufgabe A')
    expect(file_a).not_to include('Aufgabe B inaktiv')
    expect(file_b).to include('Aufgabe B inaktiv')
    expect(file_b).not_to include('Meine Aufgabe A')
  end

  it 'NEVER contains another user\'s rows (owner scope on top of tenant scope)' do
    expect(files.values.join).not_to include('Fremde Aufgabe', 'Ganz fremde Aufgabe')
  end

  it 'NEVER contains data from orgs without a membership row (D9 role model)' do
    expect(files.values.join).not_to include('Ganz fremde Aufgabe')
    expect(org_folders.join).not_to include('fremd')
  end

  # Review round 4 of #113: a heard form spoken as the account's own row of
  # the people directory is data about the account as well.
  it 'exports the heard forms the account spoke, as member and as its own directory row' do
    ActsAsTenant.with_tenant(org_a) do
      term = create(:glossary_term, organisation: org_a, term: 'Lalabase')
      own_row = create(:person, organisation: org_a, user: user, name: 'Eigene Zeile')
      other_row = create(:person, organisation: org_a, name: 'Fremde Zeile')
      create(:term_correction, organisation: org_a, glossary_term: term, heard: 'als mitglied', user: user)
      create(:term_correction, organisation: org_a, glossary_term: term, heard: 'als eigene zeile', person: own_row)
      create(:term_correction, organisation: org_a, glossary_term: term, heard: 'als fremde zeile', person: other_row)
      create(:term_correction, organisation: org_a, glossary_term: term, heard: 'als anderes mitglied', user: other_user)
    end

    rows = JSON.parse(files["organisations/#{expected_folder(org_a)}/term_corrections.json"])
    expect(rows.map { |row| row['heard'] }).to contain_exactly('als mitglied', 'als eigene zeile')
    expect(rows.map { |row| row['term'] }.uniq).to eq(['Lalabase'])
  end

  it 'writes empty sources as [] — deterministic structure' do
    folder = org_folders.first
    expect(files["organisations/#{folder}/posts.json"].strip).to eq('[]')
  end

  it 'writes every tenant source file into every org folder' do
    folder = org_folders.first
    expected = UserDataExports::Registry.tenant_sources.map(&:zip_filename)
    actual = files.keys.select { |k| k.start_with?("organisations/#{folder}/") }
                  .map { |k| k.split('/').last }
    expect(actual).to match_array(expected)
  end

  describe 'README locale' do
    it 'renders German for language_preference de' do
      expect(files['README.txt']).to include('DATENAUSKUNFT')
    end

    it 'renders English otherwise' do
      en_files = described_class.new(create(:user, language_preference: 'en')).files
      expect(en_files['README.txt']).to include('PERSONAL DATA EXPORT')
    end

    # One privacy address for both READMEs (instance admin setting, 15.09.2026). The
    # website, not the export, picks the language of the page behind it.
    it 'links the configured privacy page in both README languages' do
      en_files = described_class.new(create(:user, language_preference: 'en')).files

      expect(files['README.txt']).to include('https://public.example/datenschutz')
      expect(en_files['README.txt']).to include('https://public.example/datenschutz')
    end

    it 'omits the privacy reference when no URL is configured' do
      readme = with_legal_identity { described_class.new(user).files['README.txt'] }

      expect(readme).not_to include('stets aktuell in der Datenschutzerklärung')
    end
  end

  describe 'org folder naming edge cases' do
    it 'falls back to a non-empty folder for special-character org names' do
      cjk_org = create(:organisation, name: '###')
      ActsAsTenant.with_tenant(cjk_org) { create(:membership, user: user, organisation: cjk_org) }

      folder = described_class.new(user).files.keys
                              .find { |k| k.include?(cjk_org.id.to_s.first(8)) }
      expect(folder).to include('organisations/org-')
    end
  end

  describe 'user without any organisation' do
    it 'still produces the global part' do
      solo = create(:user)
      solo_files = described_class.new(solo).files

      expect(solo_files.keys).to include('README.txt', 'account.json')
      expect(solo_files.keys.none? { |k| k.start_with?('organisations/') }).to be(true)
    end
  end

  describe 'profile picture (S2: the one blob the export ships)' do
    it 'includes the avatar binary under its own filename' do
      user.avatar.attach(
        io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
        filename: 'me.png', content_type: 'image/png'
      )
      user.save!

      expect(files['avatar.png']).to eq(Rails.root.join('spec/fixtures/files/test_avatar.png').binread)
    end

    it 'ships no avatar entry without an attachment' do
      expect(files.keys.grep(/\Aavatar/)).to be_empty
    end

    it 'a missing blob file does not sink the export' do
      user.avatar.attach(
        io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
        filename: 'me.png', content_type: 'image/png'
      )
      user.save!
      allow_any_instance_of(ActiveStorage::Blob)
        .to receive(:download).and_raise(ActiveStorage::FileNotFoundError)

      expect(files.keys.grep(/\Aavatar/)).to be_empty
      expect(files.keys).to include('README.txt', 'account.json')
    end
  end
end
