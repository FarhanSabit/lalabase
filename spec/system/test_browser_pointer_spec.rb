# frozen_string_literal: true

require 'rails_helper'

# What: the desktop test browsers report a mouse ((hover: hover) and
#       (pointer: fine)) on every machine, the default system browser and the
#       inbox's (:inbox_e2e).
# Why:  headless Chrome answers those media queries from the input devices it
#       finds. A Mac has a mouse, a CI runner has none and reports
#       (hover: none), so the inbox drew its touch layout in CI only, and four
#       examples of spec/system/inbox_spec.rb were red there while green on
#       every Mac (2026-11-09 to 2026-11-11). LocalChrome.with_mouse pins it.
#       This spec only means something where the machine has no mouse of its
#       own: in CI. On a Mac it is green with or without the setting.
RSpec.describe 'Test browser pointer', type: :system do
  def media
    visit new_user_session_path
    expect(page).to have_css('form')
    page.evaluate_script("['(hover: hover)', '(pointer: fine)', '(hover: none)'].map(q => matchMedia(q).matches)")
  end

  it 'gives the default system browser a mouse' do
    expect(media).to eq([true, true, false])
  end

  it 'gives the inbox browser a mouse', :inbox_e2e do
    expect(media).to eq([true, true, false])
  end
end
