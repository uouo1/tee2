# frozen_string_literal: true

require "digest"
require "net/http"
require "openssl"
require "uri"
require "zlib"
require "json"

module Sources
  # Polite HTTP with on-disk caching.
  #
  # SEC asks automated clients to identify themselves and to stay under ten
  # requests a second. Everything here goes through one throttled, cached fetcher
  # so a re-run of a loader costs nothing and a first run stays within the rules.
  #
  # Port of argos/sources/http.py on Net::HTTP. Redirects are followed (urllib
  # did so implicitly); gzip/deflate bodies are decoded by hand because setting
  # Accept-Encoding ourselves switches off Net::HTTP's transparent decoding.
  module Http
    CACHE_DIR = Pathname.new(ENV.fetch("ARGOS_HTTP_CACHE") { Rails.root.join("data", "cache").to_s })
    # A generic identifier by default: never bake a personal address into the
    # code. ARGOS_USER_AGENT is where a contact goes, as SEC's policy asks.
    DEFAULT_USER_AGENT = ENV.fetch(
      "ARGOS_USER_AGENT",
      "Argos-Research-Tool/1.0 (open-source research tool; set ARGOS_USER_AGENT to your contact)"
    )
    MIN_INTERVAL_SECONDS = 0.15
    MAX_ATTEMPTS = 4
    MAX_REDIRECTS = 5
    # A client error will not get better by asking again, so any 4xx raises at
    # once — except 429, which is what SEC sends when a client exceeds ten
    # requests a second and exactly the case backoff exists for. Everything
    # else (5xx, timeouts, resets) is retried. The reference listed only 400,
    # 401, 403 and 404; the contract widens that to the whole class.
    RETRYABLE_CLIENT_STATUSES = [429].freeze
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

    class Error < StandardError; end

    # A non-2xx response. `status` lets callers tell a 404 from a 503.
    class HttpError < Error
      attr_reader :status, :url

      def initialize(status, url)
        @status = status
        @url = url
        super("HTTP #{status} for #{url}")
      end

      def client_error?
        (400..499).cover?(status)
      end
    end

    @lock = Mutex.new
    @last_request = 0.0

    class << self
      # Where cached bodies live. Writable so tests (and alternative deployments)
      # can point it elsewhere; defaults to data/cache under the repository.
      attr_writer :cache_dir

      def cache_dir
        @cache_dir ||= CACHE_DIR
      end

      # Cache file for a URL: the first 32 hex digits of its SHA-256.
      def cache_path(url, suffix = "")
        digest = Digest::SHA256.hexdigest(url.to_s.encode(Encoding::UTF_8))[0, 32]
        cache_dir.join("#{digest}#{suffix}")
      end

      # GET a URL, with a disk cache and exponential backoff on failure.
      #
      # Returns the body as a binary String (what Python returned as bytes);
      # `fetch_json` is the place that decides what text encoding it is in.
      def fetch(url, cache: true, timeout: 45, user_agent: nil)
        path = cache_path(url)
        return File.binread(path) if cache && path.exist?

        headers = {
          "User-Agent" => user_agent || DEFAULT_USER_AGENT,
          "Accept-Encoding" => "gzip, deflate",
          "Accept" => "*/*"
        }
        last_error = nil
        MAX_ATTEMPTS.times do |attempt|
          throttle
          begin
            payload = get(url, headers: headers, timeout: timeout)
            if cache
              cache_dir.mkpath
              File.binwrite(path, payload)
            end
            return payload
          rescue HttpError => e
            raise if e.client_error? && !RETRYABLE_CLIENT_STATUSES.include?(e.status)

            last_error = e
          rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
                 Net::ProtocolError, Zlib::Error => e
            last_error = e
          end
          # 1s, 2s, 4s between attempts; no point waiting after the last one.
          sleep_for(2**attempt) if attempt < MAX_ATTEMPTS - 1
        end
        raise Error, "failed to fetch #{url}: #{last_error}"
      end

      # Parsed JSON with symbol keys throughout — the convention inside Ruby.
      # Concept and unit names (:"us-gaap", :"USD/shares") become symbols too,
      # so fixtures are written with the same `"key":` literals.
      def fetch_json(url, **opts)
        body = fetch(url, **opts).dup.force_encoding(Encoding::UTF_8).scrub("�")
        JSON.parse(body, symbolize_names: true)
      end

      # Space requests at least MIN_INTERVAL_SECONDS apart, process-wide.
      def throttle
        @lock.synchronize do
          wait = MIN_INTERVAL_SECONDS - (monotonic_now - @last_request)
          sleep_for(wait) if wait.positive?
          @last_request = monotonic_now
        end
      end

      # One GET, following redirects, raising HttpError on any non-2xx status
      # and decoding a compressed body. Exposed (with `perform_request` and
      # `sleep_for`) as the seam tests replace so nothing touches the network.
      def get(url, headers:, timeout:)
        uri = URI.parse(url.to_s)
        MAX_REDIRECTS.times do
          response = perform_request(uri, headers, timeout)
          status = response.code.to_i
          if REDIRECT_STATUSES.include?(status) && response["Location"]
            uri = URI.join(uri.to_s, response["Location"])
            next
          end
          raise HttpError.new(status, uri.to_s) unless (200..299).cover?(status)

          return decode(response.body.to_s, response["Content-Encoding"])
        end
        raise Error, "too many redirects for #{url}"
      end

      def perform_request(uri, headers, timeout)
        request = Net::HTTP::Get.new(uri, headers)
        Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout
        ) { |http| http.request(request) }
      end

      def sleep_for(seconds)
        sleep(seconds) if seconds.positive?
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Servers occasionally label a zlib stream "gzip" (and vice versa), so try
      # gzip first and fall back to a raw inflate, exactly as the Python did.
      def decode(payload, encoding)
        return payload unless %w[gzip deflate].include?(encoding.to_s.downcase)

        begin
          Zlib.gunzip(payload)
        rescue Zlib::Error
          Zlib::Inflate.inflate(payload)
        end
      end
    end
  end
end
