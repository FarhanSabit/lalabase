# frozen_string_literal: true

require 'rails_helper'

# What: get_glossary refuses to run without the token of an MCP call (post-round check of #124).
# Why: the tool asks the token itself (Glossary::Lookup.for_token takes it, for the inactive
#   member's refusal). Mcp::ToolCall always sets reach and token together; a caller that set the
#   reach alone would otherwise end in a NoMethodError instead of a plain refusal.
RSpec.describe Lalabase::Tools::GetGlossary do
  it 'answers token context missing for a call with a reach but no token' do
    reach = PersonalAccessToken::Reach.new(project_ids_by_organisation: {})
    context = Lalabase::Tools::Context.new(actor: create(:user), reach: reach, token: nil)

    result = described_class.execute(args: { organisation_id: SecureRandom.uuid }, context: context)

    expect(result.error).to eq('token context missing')
  end

  it 'answers token context missing for a call without a reach' do
    context = Lalabase::Tools::Context.new(actor: create(:user))

    expect(described_class.execute(args: {}, context: context).error).to eq('token context missing')
  end
end
