# frozen_string_literal: true

module Api
  module Provisioning
    module V1
      # Creates one account for a signup the separate website collected (website
      # split, step W2.3). The decision and the write belong to
      # Actors::CreateSignup, the very actor the core's own form uses, so the two
      # funnels cannot drift apart; this controller only shapes the call and the
      # response. Contract: docs/api/provisioning_v1.md.
      class SignupsController < BaseController
        # A refusal is a 422 by default, because it is about this submission.
        # A closed instance is a 403: nothing about the submission would help.
        FORBIDDEN_CODES = %i[registration_closed].freeze

        # Not a refusal at all: the actor caught something unexpected (in
        # production it returns instead of raising). Reporting that as 422 would
        # tell the website to show the visitor a form error for a fault that is
        # ours, and it would hand out the exception message while doing it.
        INTERNAL_CODES = %i[internal_error].freeze

        # ParseError: a body that is not the JSON it claims to be. Without it the
        # exceptions app answered 400 with a body of its own, outside the envelope.
        rescue_from ActionController::ParameterMissing,
                    ActionController::BadRequest,
                    ActionDispatch::Http::Parameters::ParseError, with: :render_bad_request

        def create
          signup = Actors::CreateSignup.new(**signup_arguments)
          result = signup.call
          return render_failure(result) unless result.success?

          render json: { data: { signup: serialized(result.resource, signup.organisation) } },
                 status: :created
        end

        private

        def signup_arguments
          form = signup_params
          {
            email: form[:email], password: form[:password],
            password_confirmation: form[:password_confirmation] || form[:password],
            first_name: form[:first_name], last_name: form[:last_name],
            language: form[:language].to_s,
            terms_accepted: form[:terms_accepted] == true,
            organisation_name: form[:organisation_name],
            acquisition: form[:acquisition]&.to_h&.stringify_keys,
            founder_signup: founder_signup_attributes(form[:founder_signup]),
            request: visitor_context
          }
        end

        # Only a requested founder signup reaches the actor, and only the fields
        # the model declares. The consent timestamp is ours: the actor stamps it
        # at the moment of consent, so a client cannot backdate one.
        def founder_signup_attributes(founder)
          return if founder.blank? || founder[:requested] != true

          founder.to_h.symbolize_keys
                 .slice(*FounderSignup::DECLARED_ATTRIBUTES)
                 .merge(marketing_consent: founder[:marketing_consent] == true)
        end

        # The audit row should name the visitor, not the website server that
        # relayed the call. Fully qualified: inside Api::Provisioning, the bare
        # name would resolve to this namespace.
        def visitor_context
          ::Provisioning::RequestContext.new(remote_ip: visitor_ip, user_agent: visitor_user_agent)
        end

        def signup_params
          # require first: it answers a missing AND an empty signup, the way the
          # form's own strong parameters do.
          signup = params.require(:signup)
          object!(signup, :signup)
          object!(signup[:acquisition], :acquisition) if signup[:acquisition].present?
          object!(signup[:founder_signup], :founder_signup) if signup[:founder_signup].present?

          signup.permit(
            :email, :password, :password_confirmation, :first_name, :last_name,
            :language, :terms_accepted, :organisation_name,
            acquisition: AcquisitionSource::KEYS,
            founder_signup: [:requested, :marketing_consent, *FounderSignup::DECLARED_ATTRIBUTES]
          )
        end

        # sign_in_url is what keeps the funnel as short as it was: the website
        # cannot open a session here, so it sends the browser through this link.
        def serialized(user, organisation)
          {
            user_id: user.id,
            organisation_id: organisation&.id,
            confirmation_required: !user.confirmed?,
            sign_in_url: Signups::Handoff.url_for(user: user)
          }
        end

        # A value that is not an object reaches #permit as a String or an Array and
        # takes the request down with a NoMethodError. The shape is the caller's
        # to get right, so it gets the documented 400 instead of a crash.
        def object!(value, key)
          return if value.is_a?(ActionController::Parameters)

          raise ActionController::BadRequest, "#{key} must be an object"
        end

        def render_failure(result)
          return render_error(:internal_server_error, result.code) if INTERNAL_CODES.include?(result.code)

          status = FORBIDDEN_CODES.include?(result.code) ? :forbidden : :unprocessable_content
          render_error(status, result.code, messages: result.errors)
        end

        # The message here names the missing or misshapen key, which is the
        # caller's own input and nothing of ours.
        def render_bad_request(exception)
          render_error(:bad_request, :bad_request, messages: [exception.message])
        end
      end
    end
  end
end
