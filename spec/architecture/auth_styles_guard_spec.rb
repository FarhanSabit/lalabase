# frozen_string_literal: true

require 'rails_helper'

# The sign-in pages (app/views/devise, layout application_auth) look like the public
# pages of lalabase-website since 05.11.2026: "brutalism light", the guide of that
# repository (doc/design/DESIGN.md there). landing_tokens.css and lp_base.css are
# word-for-word mirrors of the website's, auth.css is the website's plus an appendix for
# the pieces only these pages have.
#
# The rules below are the ones of that guide a stylesheet can break without anybody
# noticing in a diff, the same checks the website runs on its copies: a soft shadow on a
# new box, a gradient, light text on a lime ground (white on #BEF264 measures 1.3:1), a
# hard shadow on something that is not where the eye should go first, and the signal
# orange the old pages used as a second accent.
module AuthStyles
  STYLESHEETS = Rails.root.join('app/assets/stylesheets')
  FILES = %w[auth.css lp_base.css landing_tokens.css].map { |name| STYLESHEETS.join(name) }.freeze

  LIGHT_TEXT = /color:\s*(var\(--lp-white\)|var\(--lp-on-dark(-2)?\)|#fff\b|#ffffff\b|white\b)/i
  LIME_GROUND = /background(-color)?:\s*var\(--lp-accent\)/

  # At rest a hard shadow stands only where the eye should go first: the primary door,
  # the drawn window of the product, the one highlighted term. A selector for a state
  # (hover, press, focus, an error) may throw one anyway.
  SHADOW_AT_REST = [/\.lp-btn--(primary|dark)\b/, /\.lp-auth-win\b/, /\.lp-mark\b/].freeze
  STATE = /:(hover|active|focus|focus-visible|focus-within)\b|aria-pressed="true"|\.is-open\b|--error\b/
end

RSpec.describe 'Sign-in page stylesheets follow the website guide', type: :model do
  # Every rule block of every file, as "file: selector" => declarations, comments removed.
  def rules
    AuthStyles::FILES.flat_map do |path|
      css = path.read.gsub(%r{/\*.*?\*/}m, '')
      css.scan(/([^{}]+)\{([^{}]*)\}/).map do |selector, body|
        ["#{path.basename}: #{selector.strip.gsub(/\s+/, ' ')}", body]
      end
    end
  end

  def shadows
    rules.flat_map { |name, body| body.scan(/box-shadow:\s*([^;]+);/).flatten.map { [name, _1.strip] } }
  end

  # A shadow's third length is its blur; tokens (var(...)) are checked where defined.
  def blurred?(value)
    return false if value.start_with?('none', 'var(')

    value.split(/,(?![^(]*\))/).any? do |shadow|
      lengths = shadow.scan(/-?\d*\.?\d+(?:px|em|rem)?(?=\s|$)/)
      lengths.size >= 3 && lengths[2].to_f.positive?
    end
  end

  # An offset shadow: tokens count; a focus ring (0 0 0 3px) or a flat press does not.
  def offset?(value)
    return false if value.start_with?('none')
    return true if value.start_with?('var(')

    value.split(/,(?![^(]*\))/).any? do |shadow|
      shadow.scan(/-?\d*\.?\d+(?:px)?(?=\s|$)/).first(2).any? { |length| length.to_f.nonzero? }
    end
  end

  def shadow_allowed?(selector)
    selector.match?(AuthStyles::STATE) || AuthStyles::SHADOW_AT_REST.any? { selector.match?(_1) }
  end

  it 'reads rules at all' do
    # Without this every guard below passes the day a file moves.
    expect(rules.size).to be > 100
  end

  it 'draws every shadow hard, without blur' do
    soft = shadows.select { |_, value| blurred?(value) }.map { |name, value| "#{name}: #{value}" }

    expect(soft).to be_empty, "Soft shadows:\n#{soft.join("\n")}"
  end

  it 'throws a shadow at rest only where the eye should go first' do
    offenders = shadows.select { |_, value| offset?(value) }.flat_map do |name, value|
      file, selectors = name.split(': ', 2)
      selectors.split(',').map(&:strip).reject { shadow_allowed?(_1) }.map { "#{file}: #{_1} (#{value})" }
    end

    expect(offenders).to be_empty, "Shadows at rest outside the list:\n#{offenders.join("\n")}"
  end

  it 'uses no gradient' do
    expect(rules.filter_map { |name, body| name if body.include?('gradient(') }).to be_empty
  end

  it 'never sets light text on the lime ground' do
    offenders = rules.filter_map do |name, body|
      name if body.match?(AuthStyles::LIME_GROUND) && body.match?(AuthStyles::LIGHT_TEXT)
    end

    expect(offenders).to be_empty, "Light text on lime:\n#{offenders.join("\n")}"
  end

  # The alert flash drew its bar in var(--lp-signal) until 05.11.2026; the token is gone
  # with the second accent, and a var() of an undefined token draws nothing at all.
  it 'brings back no second accent' do
    css = AuthStyles::FILES.map(&:read).join("\n")

    expect(css).not_to match(/#E4552B/i)
    expect(css).not_to include('--lp-signal')
  end
end
