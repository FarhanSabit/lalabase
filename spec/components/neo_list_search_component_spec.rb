# frozen_string_literal: true

require 'rails_helper'

# What: NeoListSearchComponent, the search of a list head with the bar of the
#       ticket list but without its filter bar (the inbox, "Personen").
# Type: Component spec.
# Why:  One copy of the magnifier that grows into the field (user,
#       2026-11-11): the inbox carried it alone, the people page would have
#       been the second copy and the glossary the third. It speaks the filter
#       bar's markers (data-fb-search, components/filter_bar.css), folds
#       through search-disclosure and submits itself into the list frame.
RSpec.describe NeoListSearchComponent, type: :component do
  def search(**overrides)
    described_class.new(url: '/people', name: :q, value: nil, input_id: 'people-search', frame: 'people_results',
                        label: 'Personen durchsuchen', placeholder: 'Name, Funktion oder Firma',
                        form_class: 'people-search', **overrides)
  end

  it 'is a magnifier while empty, with the field folded behind it' do
    render_inline(search)

    box = page.find('[data-fb-search]', visible: :all)
    expect(box['data-controller']).to eq('search-disclosure')
    expect(box.native.key?('data-fb-search-open')).to be(false)
    button = page.find('button[data-fb-search-open-button]')
    expect(button['aria-label']).to eq('Personen durchsuchen')
    expect(button['title']).to eq('Personen durchsuchen')
    expect(button['data-action']).to eq('click->search-disclosure#open')
  end

  it 'stands open while a term is typed, the term in the field' do
    render_inline(search(value: 'Hansen'))

    expect(page.find('[data-fb-search]', visible: :all).native.key?('data-fb-search-open')).to be(true)
    expect(page.find('input#people-search', visible: :all)['value']).to eq('Hansen')
  end

  it 'takes a term that is no string for none' do
    render_inline(search(value: { 'x' => '1' }))

    expect(page.find('[data-fb-search]', visible: :all).native.key?('data-fb-search-open')).to be(false)
    expect(page.find('input#people-search', visible: :all)['value']).to be_nil
  end

  it 'submits itself into the list frame, without an action of its own unless given' do
    render_inline(search)

    form = page.find('form.people-search', visible: :all)
    expect(form['action']).to eq('/people')
    expect(form['method']).to eq('get')
    expect(form['data-controller']).to eq('auto-submit')
    expect(form['data-turbo-frame']).to eq('people_results')
    expect(form['data-turbo-action']).to be_nil

    render_inline(search(turbo_action: 'replace'))
    expect(page.find('form.people-search', visible: :all)['data-turbo-action']).to eq('replace')
  end

  it 'names the field, folds it on Escape and on leaving it empty' do
    render_inline(search)

    input = page.find('input[type="search"][name="q"]', visible: :all)
    expect(input['aria-label']).to eq('Personen durchsuchen')
    expect(input['placeholder']).to eq('Name, Funktion oder Firma')
    expect(input['autocomplete']).to eq('off')
    expect(input['data-search-disclosure-target']).to eq('input')
    expect(input['data-action']).to include('keydown.esc->search-disclosure#close', 'focusout->search-disclosure#blur')
    expect(page).to have_css('[data-fb-depth]', visible: :all)
  end

  it 'renders the hidden fields it is given inside the form, and the extras of the box' do
    render_inline(search(button_label: 'Suchen', wrapper_class: 'ms-auto', wrapper_data: { inbox_tool: 'search' })) do
      '<input type="hidden" name="kind" value="contacts">'.html_safe
    end

    box = page.find('[data-fb-search]', visible: :all)
    expect(box[:class]).to include('ms-auto', 'self-center')
    expect(box['data-inbox-tool']).to eq('search')
    expect(page).to have_css('form.people-search input[type="hidden"][name="kind"][value="contacts"]', visible: :all)
    expect(page.find('button[data-fb-search-open-button]')['title']).to eq('Suchen')
  end
end
