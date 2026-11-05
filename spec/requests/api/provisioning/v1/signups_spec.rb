# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/provisioning/v1/signups' do
  let(:secret) { SecureRandom.hex(32) }
  let(:configuration) { Lalabase::ProvisioningConfiguration.new(secret: secret) }
  let(:visitor_ip) { '203.0.113.7' }
  let(:headers) do
    {
      'Authorization' => "Bearer #{secret}",
      'X-Lalabase-Visitor-IP' => visitor_ip,
      'X-Lalabase-Visitor-User-Agent' => 'Mozilla/5.0 (visitor)',
      'CONTENT_TYPE' => 'application/json'
    }
  end
  let(:signup) do
    {
      email: 'api-signup@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      first_name: 'API',
      last_name: 'Signup',
      organisation_name: 'API Organisation',
      language: 'en',
      terms_accepted: true
    }
  end

  around do |example|
    previous = Rails.configuration.x.provisioning
    Rails.configuration.x.provisioning = configuration
    example.run
  ensure
    Rails.configuration.x.provisioning = previous
  end

  def post_signup(payload: signup, request_headers: headers)
    post '/api/provisioning/v1/signups', params: { signup: payload }.to_json, headers: request_headers
  end

  def response_error
    response.parsed_body.fetch('error')
  end

  describe 'the door itself' do
    it 'does not exist without a configured secret' do
      Rails.configuration.x.provisioning = Lalabase::ProvisioningConfiguration.new

      expect { post_signup }.not_to change(User, :count)
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses a missing or wrong secret' do
      post_signup(request_headers: headers.except('Authorization'))
      expect(response).to have_http_status(:unauthorized)

      post_signup(request_headers: headers.merge('Authorization' => "Bearer #{SecureRandom.hex(32)}"))
      expect(response).to have_http_status(:unauthorized)
      expect(User.find_by(email: signup[:email])).to be_nil
    end

    it 'refuses a personal access token, which belongs to a person and not to a server' do
      organisation = create(:organisation)
      token = create(:personal_access_token, organisations: [organisation]).token

      post_signup(request_headers: headers.merge('Authorization' => "Bearer #{token}"))

      expect(response).to have_http_status(:unauthorized)
    end

    # That the body stays UNREAD is pinned in body_limit_spec.rb, which watches
    # the parser; here only the answer the caller sees.
    it 'refuses a body larger than the limit' do
      oversized = signup.merge(organisation_name: 'x' * Lalabase::ProvisioningConfiguration::MAX_BODY_BYTES)

      expect { post_signup(payload: oversized) }.not_to change(User, :count)
      expect(response).to have_http_status(:content_too_large)
      expect(response_error.fetch('code')).to eq('body_too_large')
    end

    it 'answers a body without the signup key with a bad request' do
      post '/api/provisioning/v1/signups', params: {}.to_json, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(response_error.fetch('code')).to eq('bad_request')
    end

    it 'answers a signup that is not an object with a bad request, not a crash' do
      post '/api/provisioning/v1/signups', params: { signup: 'wrong' }.to_json, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(response_error.fetch('code')).to eq('bad_request')
    end

    # A body cut off mid-object raised ParseError, which the controller did not
    # rescue: the exceptions app answered 400 with its own body, without the
    # envelope the website branches on.
    it 'answers a body that is no JSON with a bad request in the envelope' do
      post '/api/provisioning/v1/signups', params: '{"signup": {', headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(response_error.fetch('code')).to eq('bad_request')
      expect(User.find_by(email: signup[:email])).to be_nil
    end

    it 'answers a misshapen nested value with a bad request' do
      post_signup(payload: signup.merge(acquisition: %w[utm_source website]))
      expect(response).to have_http_status(:bad_request)

      post_signup(payload: signup.merge(founder_signup: %w[requested true]))
      expect(response).to have_http_status(:bad_request)
      expect(User.find_by(email: signup[:email])).to be_nil
    end

    it 'opens no session for the server that calls it' do
      post_signup

      expect(response.headers).not_to have_key('Set-Cookie')
    end
  end

  describe 'a complete signup' do
    # Counted by address on purpose: a signup also brings the internal system
    # user into being on a fresh instance, the same as the core's own form does.
    it 'creates the user and their organisation through the shared actor' do
      expect { post_signup }.to change { User.where(email: signup[:email]).count }.by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body.dig('data', 'signup')
      user = User.find(body.fetch('user_id'))
      expect(user.email).to eq('api-signup@example.com')
      expect(user.language_preference).to eq('en')
      expect(user).not_to be_confirmed
      expect(body.fetch('confirmation_required')).to be(true)
      expect(Organisation.find(body.fetch('organisation_id')).name).to eq('API Organisation')
    end

    # Without it the website would have to send the new customer to the sign-in
    # form it just took a password for.
    it 'carries the one-time sign-in link the website sends the browser to' do
      post_signup

      url = response.parsed_body.dig('data', 'signup', 'sign_in_url')
      expect(url).to include('/users/signup_handoff?token=')
      expect(Signups::Handoff.claim(token: url[/token=([^&]+)/, 1]))
        .to eq(User.find_by!(email: signup[:email]))
    end

    # The mail goes out through deliver_later, and the test environment runs Active Job on
    # Solid Queue: with_delivered_mails sets the test adapter for the block. A bare
    # perform_enqueued_jobs passed only when an earlier spec had left that adapter behind.
    it 'sends the confirmation mail in the language the visitor signed up in' do
      with_delivered_mails { post_signup(payload: signup.merge(language: 'de')) }

      expect(ActionMailer::Base.deliveries.last.subject).to eq(
        I18n.t('devise.mailer.confirmation_instructions.subject', locale: :de)
      )
    end

    it 'names the visitor in the audit row, not the website that relayed the call' do
      post_signup

      activity = UserActivity.order(:created_at).last
      expect(activity.ip_address).to eq(visitor_ip)
      expect(activity.user_agent).to eq('Mozilla/5.0 (visitor)')
    end

    it 'stores the acquisition source the website collected' do
      post_signup(payload: signup.merge(acquisition: { 'utm_source' => 'website',
                                                       'landing_path' => '/en/pricing' }))

      account = Organisation.find_by!(name: 'API Organisation').account
      expect(account.acquisition).to include('utm_source' => 'website', 'landing_path' => '/en/pricing')
    end

    it 'records a founder request but stamps the consent itself' do
      payload = signup.merge(
        founder_signup: {
          requested: true,
          company_name: 'API Organisation GmbH',
          company_seat: 'Berlin',
          founded_on: 6.months.ago.to_date.iso8601,
          revenue_band: FounderSignup::REVENUE_BAND_UP_TO_50K,
          phone: '+49 30 123456',
          marketing_consent: true,
          marketing_consent_at: 2.years.ago.iso8601
        }
      )

      post_signup(payload: payload)

      expect(response).to have_http_status(:created)
      founder_signup = FounderSignup.sole
      expect(founder_signup.marketing_consent).to be(true)
      expect(founder_signup.marketing_consent_at).to be_within(5.seconds).of(Time.current)
    end

    it 'ignores a founder block that was not requested' do
      post_signup(payload: signup.merge(founder_signup: { requested: false, company_name: 'Ghost' }))

      expect(response).to have_http_status(:created)
      expect(FounderSignup.count).to eq(0)
    end
  end

  describe 'a refused signup' do
    it 'writes nothing and names the reason when the terms were not accepted' do
      expect { post_signup(payload: signup.merge(terms_accepted: false)) }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response_error.fetch('code')).to eq('terms_not_accepted')
      expect(response_error.fetch('messages')).to be_present
    end

    it 'answers a closed instance with forbidden, because no submission would help' do
      allow(SystemSetting).to receive(:allow_registration?).and_return(false)

      post_signup

      expect(response).to have_http_status(:forbidden)
      expect(response_error.fetch('code')).to eq('registration_closed')
    end

    it 'reports an invalid record without creating half of it' do
      expect { post_signup(payload: signup.merge(email: 'not-an-address')) }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(Organisation.find_by(name: 'API Organisation')).to be_nil
    end

    # There is no request locale here: nothing sets one for an API controller,
    # so the messages come out in the instance default unless the signup's own
    # language is still in force while they are rendered.
    it 'speaks the language the visitor signed up in' do
      post_signup(payload: signup.merge(email: 'not-an-address', language: 'en'))
      expect(response_error.fetch('messages')).to include(a_string_matching(/is invalid/i))

      post_signup(payload: signup.merge(email: 'not-an-address', language: 'de'))
      expect(response_error.fetch('messages')).to include(a_string_matching(/ungültig/i))
    end

    # In production the actor returns instead of raising, so without this the
    # website would show the visitor a form error for a fault that is ours, with
    # the exception message in it.
    it 'reports an unexpected failure as a server error and keeps the detail to itself' do
      failure = Actors::BaseActor::Result.new(success: false, errors: ['PG::ConnectionBad: could not connect'],
                                              code: :internal_error)
      allow(Actors::CreateSignup).to receive(:new).and_return(instance_double(Actors::CreateSignup, call: failure))

      post_signup

      expect(response).to have_http_status(:internal_server_error)
      expect(response_error.fetch('code')).to eq('internal_error')
      expect(response.body).not_to include('PG::ConnectionBad')
    end

    it 'refuses a language the instance does not speak' do
      post_signup(payload: signup.merge(language: 'fr'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response_error.fetch('code')).to eq('invalid_language')
      expect(User.find_by(email: signup[:email])).to be_nil
    end
  end
end
