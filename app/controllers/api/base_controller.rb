# frozen_string_literal: true

module Api
  # Shared plumbing for the JSON API. Port of argos/server.py's dispatch and of
  # the parameter helpers at the top of argos/api.py.
  #
  # The reference handlers were plain functions of (params, body) where params
  # was parse_qs output: every key a list, so a repeated `?doc_type=` arrives
  # whole. Rack keeps only the last value of a repeated key without `[]`, so
  # the query string is parsed here the parse_qs way instead of through
  # `params`. The body is parsed here too, so an invalid JSON body is the
  # reference's 400 "invalid JSON body" and never reaches Rails' own parser.
  #
  # There is no authentication: like the reference, the API is meant to run on
  # an analyst's own machine (docs/RAILS_PORT.md item 9). That is also why
  # POST /api/ingest reads only under data/.
  class BaseController < ActionController::API
    # The reference's MAX_BODY_BYTES: large enough for a corpus batch, small
    # enough that one request cannot exhaust memory.
    MAX_BODY_BYTES = 8 * 1024 * 1024
    FALSE_VALUES = %w[0 false no].freeze
    VERBS = %w[GET POST PATCH PUT DELETE].freeze

    # An error with an HTTP status attached (the reference's ApiError).
    # Handlers raise it; rescue_from turns it into {"error": message}.
    class Error < StandardError
      attr_reader :status

      def initialize(message, status = 400)
        super(message)
        @status = status
      end
    end

    # The body is parsed by #body; nothing should wrap it into params.
    wrap_parameters false

    before_action :reject_large_body

    # rescue_from handlers are matched last-declared first, so the catch-all
    # comes first and the specific ones after it.
    rescue_from StandardError, with: :render_internal_error
    rescue_from ActiveRecord::RecordNotFound do |exc|
      render_error(exc.message, 404)
    end
    rescue_from ActionDispatch::Http::Parameters::ParseError do |exc|
      render_error("invalid JSON body: #{exc.message}", 400)
    end
    rescue_from Error do |exc|
      render_error(exc.message, exc.status)
    end

    # The target of the API's catch-all route: 405 with the allowed methods
    # when the path exists under another verb, else 404 — the reference's
    # behaviour for anything its route table did not match.
    def route_not_found
      path = request.path
      allowed = allowed_methods(path)
      if allowed.any?
        response.set_header("Allow", allowed.join(", "))
        render json: { error: "method not allowed", allowed: allowed }, status: 405
      else
        render json: { error: "no such endpoint", path: path }, status: 404
      end
    end

    private

    # ----------------------------------------------------------- responses

    def render_error(message, status)
      render json: { error: message }, status: status
    end

    # Surfaced to the client as the reference did ("KeyError: 'x'"), and
    # logged with its backtrace so the server log explains it.
    def render_internal_error(exc)
      Rails.logger.error("#{exc.class.name}: #{exc.message}\n#{Array(exc.backtrace).first(20).join("\n")}")
      render_error("#{exc.class.name}: #{exc.message}", 500)
    end

    # ------------------------------------------------------------ requests

    def reject_large_body
      return unless %w[POST PATCH PUT].include?(request.request_method)

      raise Error.new("request body too large", 413) if request.content_length.to_i > MAX_BODY_BYTES
    end

    # The query string as parse_qs returned it: {"key" => ["v1", "v2"]}.
    # "key[]" is folded into "key" so either spelling of a repeated filter works.
    def query
      @query ||= Rack::Utils.parse_query(request.query_string.to_s).each_with_object({}) do |(key, value), out|
        name = key.to_s.delete_suffix("[]")
        (out[name] ||= []).concat(Array(value).map(&:to_s))
      end
    rescue ArgumentError, Rack::Utils::InvalidParameterError => e
      raise Error, "invalid query string: #{e.message}"
    end

    # _first: the first value of a query key, or the default.
    def first(key, default = nil)
      values = query[key.to_s]
      values.nil? || values.empty? ? default : values.first
    end

    # _int: an integer query value; blank or malformed falls back to the default.
    def int_param(key, default)
      raw = first(key)
      return default if raw.nil? || raw.strip.empty?

      Integer(raw.strip, 10)
    rescue ArgumentError, TypeError
      default
    end

    # _bool: absent is the default; "0", "false", "no" and "" are false.
    def bool_param(key, default = false)
      raw = first(key)
      return default if raw.nil?

      !(FALSE_VALUES.include?(raw.to_s.downcase) || raw.to_s.empty?)
    end

    # The JSON body (symbol keys), {} when empty. Anything that is not JSON is
    # a 400, as in the reference's _read_body.
    def body
      return @body if defined?(@body)

      raw = request.raw_post.to_s
      @body =
        if raw.strip.empty?
          {}
        else
          begin
            JSON.parse(raw.dup.force_encoding(Encoding::UTF_8), symbolize_names: true)
          rescue JSON::ParserError, EncodingError => e
            raise Error, "invalid JSON body: #{e.message}"
          end
        end
    end

    # The body when it is an object; handlers that need fields read this.
    def body_hash
      body.is_a?(Hash) ? body : {}
    end

    # An integer path segment (:id). The routes take any segment, the
    # reference took only \d+, so anything else is "not found".
    def path_int(key = :id)
      raw = request.path_parameters[key].to_s
      raise Error.new("no such endpoint", 404) unless raw.match?(/\A\d+\z/)

      raw.to_i
    end

    def path_param(key)
      request.path_parameters[key].to_s
    end

    # Verbs under which some API route (other than the catch-all) matches.
    def allowed_methods(path)
      VERBS.select do |verb|
        recognized = Rails.application.routes.recognize_path(path, method: verb)
        recognized[:controller] != "api/base"
      rescue ActionController::RoutingError
        false
      end
    end
  end
end
