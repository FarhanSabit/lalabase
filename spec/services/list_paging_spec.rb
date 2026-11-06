# frozen_string_literal: true

require 'rails_helper'

# The strict reading of one paging value (ListPaging.strict_number): the one rule of the lists
# that refuse what they cannot read, the glossary (REST and MCP) and, over /api/v1, the people
# directory and the knowledge and meetings lists. The lenient ListPaging.page and .per_page are
# held where their lists are read (Tickets::Filter, list_tickets).
RSpec.describe ListPaging, :ci_guard do
  describe '.strict_number' do
    def strict(value, name: :per_page, default: 50, max: 100)
      described_class.strict_number(value, name: name, default: default, max: max)
    end

    it 'takes an absent or empty value as the default' do
      expect(strict(nil)).to eq(50)
      expect(strict('')).to eq(50)
    end

    it 'takes a whole number from 1 to max, as text (a query string) or as a JSON number' do
      expect(strict('1')).to eq(1)
      expect(strict('100')).to eq(100)
      expect(strict('007')).to eq(7)
      expect(strict(42)).to eq(42)
    end

    # JSON Schema counts 2.0 as an integer, so the MCP SDK lets it through and a client that
    # sends numbers as floats sends it.
    it 'takes a whole number written with a point (2.0) as that number' do
      expect(strict(2.0)).to eq(2)
    end

    it 'refuses whatever is no whole number from 1 to max' do
      ['0', '101', '-1', '+2', ' 2', '2 ', '1.5', '2.0', 'x', '1e2', 0, 101, -1, 2.5, 0.0,
       Float::INFINITY, Float::NAN, ['2'], { 'a' => '1' }, true].each do |value|
        expect { strict(value) }.to raise_error(described_class::InvalidArgument), "value #{value.inspect}"
      end
    end

    it 'names the refused value and what it takes, in English' do
      I18n.with_locale(:en) do
        expect { strict('101') }
          .to raise_error(described_class::InvalidArgument, 'invalid per_page "101" (expected a whole number from 1 to 100)')
        expect { strict(2.5, name: :page, max: 100_000) }
          .to raise_error(described_class::InvalidArgument, 'invalid page "2.5" (expected a whole number from 1 to 100000)')
      end
    end

    it 'names them in German' do
      I18n.with_locale(:de) do
        expect { strict('101') }
          .to raise_error(described_class::InvalidArgument,
                          'ungültiger Wert für per_page "101" (erwartet ist eine ganze Zahl von 1 bis 100)')
      end
    end

    # The message names the refused value, but mirrors no amount of input back, and never
    # Ruby's insides of a list or a nested value.
    it 'quotes only the start of a text or a number, and nothing of a list or a hash' do
      I18n.with_locale(:en) do
        expect { strict('9' * 5000) }.to raise_error(described_class::InvalidArgument) { |error|
          expect(error.message).to start_with('invalid per_page "99999999999999999..." (expected')
          expect(error.message.length).to be < 100
        }
        [['2'], { 'a' => '1' }, true].each do |value|
          expect { strict(value) }
            .to raise_error(described_class::InvalidArgument, 'invalid per_page (expected a whole number from 1 to 100)')
        end
      end
    end
  end
end
