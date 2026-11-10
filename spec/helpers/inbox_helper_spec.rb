# frozen_string_literal: true

require 'rails_helper'

# The addresses of the inbox list head. A link changes one dimension of the
# list and carries the others along; what is not a dimension of the list (the
# open notification, a page, a stray key of a hand-made address) never
# travels. A list rendered by a stream passes its own state (query:), because
# the request it answers is an action, not the inbox.
RSpec.describe InboxHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:inbox) { '/org/acme/inbox' }

  before do
    org = organisation # the block runs as the helper, where the let is unknown
    helper.define_singleton_method(:current_organisation) { org }
    allow(helper).to receive(:organisation_notifications_path).with(organisation).and_return(inbox)
  end

  def with_query(query)
    allow(helper.request).to receive(:query_parameters).and_return(query)
  end

  def query_of(url)
    Rack::Utils.parse_nested_query(URI.parse(url).query.to_s)
  end

  describe '#inbox_status_view_url' do
    it 'sets the state filters of the view and keeps search, project and view mode' do
      with_query('state_filters' => ['unread'], 'search' => 'x', 'project_id' => 'p1', 'view_mode' => 'chronological')

      expect(query_of(helper.inbox_status_view_url('all')))
        .to eq('state_filters' => %w[read unread], 'search' => 'x', 'project_id' => 'p1', 'view_mode' => 'chronological')
    end

    it 'drops the open notification, the page and the legacy state' do
      with_query('state_filters' => ['unread'], 'notification' => 'abc', 'page' => '2', 'items' => '20', 'state' => 'read')

      expect(query_of(helper.inbox_status_view_url('archived'))).to eq('state_filters' => ['archived'])
    end

    it 'drops a key that is no dimension of the list' do
      with_query('state_filters' => ['unread'], 'partial' => 'list', 'format' => 'json', 'submit' => 'x')

      expect(query_of(helper.inbox_status_view_url('unread'))).to eq('state_filters' => ['unread'])
    end

    it 'takes the passed list state over the request (a stream answers an action address)' do
      with_query('search' => 'from-the-request')

      url = helper.inbox_status_view_url('all', query: { state_filters: ['unread'], project_id: 'p1' })

      expect(query_of(url)).to eq('state_filters' => %w[read unread], 'project_id' => 'p1')
    end

    it 'refuses a view it does not know' do
      with_query({})

      expect { helper.inbox_status_view_url('gelesen') }.to raise_error(KeyError)
    end
  end

  describe '#inbox_view_mode_url' do
    it 'keeps the status view and the narrowing' do
      with_query('state_filters' => ['unread'], 'search' => 'x')

      expect(query_of(helper.inbox_view_mode_url('chronological')))
        .to eq('state_filters' => ['unread'], 'search' => 'x', 'view_mode' => 'chronological')
    end
  end

  describe '#inbox_reset_narrowing_url' do
    it 'drops search, project and type and keeps the status view' do
      with_query('state_filters' => ['unread'], 'search' => 'x', 'project_id' => 'p1', 'event_type' => 'mention', 'view_mode' => 'grouped')

      expect(query_of(helper.inbox_reset_narrowing_url)).to eq('state_filters' => ['unread'], 'view_mode' => 'grouped')
    end

    it 'is the bare list address when nothing remains' do
      with_query('search' => 'x')

      expect(helper.inbox_reset_narrowing_url).to eq(inbox)
    end
  end

  describe '#inbox_notification_url' do
    let(:notification) { instance_double(Notification, id: 'n-1') }

    it 'opens the notification over the list state and nothing else of the address' do
      with_query('state_filters' => ['unread'], 'search' => 'x', 'notification' => 'old', 'page' => '3', 'submit' => 'x')

      expect(query_of(helper.inbox_notification_url(notification)))
        .to eq('state_filters' => ['unread'], 'search' => 'x', 'notification' => 'n-1')
    end

    it 'takes the passed list state over the request' do
      with_query('search' => 'from-the-request')

      expect(query_of(helper.inbox_notification_url(notification, query: { project_id: 'p1' })))
        .to eq('project_id' => 'p1', 'notification' => 'n-1')
    end
  end

  describe 'the type filter' do
    it 'names the type that narrows the list, and the address without it' do
      with_query('state_filters' => ['unread'], 'event_type' => 'mention')

      expect(helper.inbox_event_type_filter).to eq('mention')
      expect(query_of(helper.inbox_without_event_type_url)).to eq('state_filters' => ['unread'])
    end

    it 'words the type as the model does, in the language of the page' do
      I18n.with_locale(:de) { expect(helper.inbox_event_type_label('mention')).to eq('Erwähnung') }
      I18n.with_locale(:en) { expect(helper.inbox_event_type_label('mention')).to eq('Mention') }
    end

    it 'takes a type that does not exist for no filter: no chip, and it does not travel' do
      with_query('state_filters' => ['unread'], 'event_type' => 'nope')

      expect(helper.inbox_event_type_filter).to be_nil
      expect(query_of(helper.inbox_status_view_url('all'))).to eq('state_filters' => %w[read unread])
      expect(helper.inbox_hidden_query_fields(except: [])).not_to include('nope')
    end

    it 'takes a nested value for no filter' do
      with_query('event_type' => { 'a' => 'mention' })

      expect(helper.inbox_event_type_filter).to be_nil
    end
  end

  describe '#inbox_hidden_query_fields' do
    def fields(except:)
      Nokogiri::HTML.fragment(helper.inbox_hidden_query_fields(except: except)).css('input').to_h do |input|
        [input['name'], input['value']]
      end
    end

    it 'writes an array as one field per item and a string as one field, without the excepted keys' do
      with_query('state_filters' => %w[read unread], 'search' => 'x', 'project_id' => 'p1')

      inputs = Nokogiri::HTML.fragment(helper.inbox_hidden_query_fields(except: %w[search])).css('input')

      expect(inputs.map { |i| [i['type'], i['name'], i['value']] }).to contain_exactly(
        %w[hidden state_filters[] read], %w[hidden state_filters[] unread], %w[hidden project_id p1]
      )
      expect(inputs.map { |i| i['id'] }).to all(be_nil)
    end

    it 'drops a nested hash, non-string items of an array and keys that are no dimension of the list' do
      with_query('state_filters' => ['unread', { 'a' => 'b' }], 'search' => { 'nested' => '1' }, 'requestSubmit' => 'x')

      expect(fields(except: [])).to eq('state_filters[]' => 'unread')
    end

    it 'renders nothing for an empty list state' do
      with_query('notification' => 'abc')

      expect(helper.inbox_hidden_query_fields(except: [])).to eq('')
    end
  end
end
