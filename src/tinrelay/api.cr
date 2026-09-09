require "uri"

module Tinrelay
  class ServerConfig
    getter bind : String
    getter port : Int32
    getter database_path : String
    getter bootstrap_template : String
    getter source_repository : String
    getter database_connections : Int32
    getter permanent_metadata_limit : Int64
    getter configuration_path : String?

    def initialize(@bind = "127.0.0.1", @port = 8787,
                   @database_path = "tinrelay.db",
                   @bootstrap_template = "templates/common-bootstrap.md",
                   @source_repository = "https://github.com/mieko/tinrelay",
                   @database_connections = System.cpu_count,
                   @permanent_metadata_limit = DEFAULT_PERMANENT_METADATA_LIMIT,
                   @configuration_path = nil)
    end
  end

  class RuntimeSnapshot
    getter page : BootstrapPage
    getter registration_allowances : RegistrationAllowances
    getter client_address_policy : ClientAddressPolicy
    @registration_deny_cidrs : Array(IPNetwork)

    def initialize(@page, @registration_allowances,
                   registration_deny_cidrs : Array(IPNetwork),
                   @client_address_policy)
      @registration_deny_cidrs = registration_deny_cidrs.dup
    end

    def registration_deny_cidrs : Array(IPNetwork)
      @registration_deny_cidrs.dup
    end
  end

  class API
    MAX_REQUEST_BYTES       = 64 * 1024
    ACCEPTANCE_TARGET       = 250.milliseconds
    REGISTRATION_WINDOW_KEY = "all"

    getter config : ServerConfig
    getter database : Database
    getter store : Store
    getter handoffs : DirectHandoff
    getter metrics : Metrics
    getter submission_window : SubmissionWindow
    getter hail_window : SubmissionWindow
    @runtime_snapshot : Atomic(RuntimeSnapshot)

    def initialize(@config)
      @runtime_snapshot = Atomic(RuntimeSnapshot).new(load_runtime_snapshot(true))
      @database = Database.new(config.database_path, config.database_connections)
      @store = Store.new(database, config.permanent_metadata_limit)
      @handoffs = DirectHandoff.new
      @metrics = Metrics.new
      @submission_window = SubmissionWindow.new
      @hail_window = SubmissionWindow.new(Store::MAX_HAILS_PER_DAY, 24 * 60 * 60)
      @registration_window = SubmissionWindow.new(
        MAX_SHIP_REGISTRATIONS_PER_HOUR, 60 * 60
      )
    end

    def runtime_snapshot : RuntimeSnapshot
      @runtime_snapshot.get(:acquire)
    end

    def bootstrap_page : BootstrapPage
      runtime_snapshot.page
    end

    def reload_configuration : Nil
      candidate = load_runtime_snapshot(false)
      @runtime_snapshot.set(candidate, :release)
    end

    def handler
      HTTP::Handler::HandlerProc.new do |context|
        started = Time.instant
        status = 500
        begin
          status = route(context)
        rescue ex : JSON::ParseException
          status = error(context, 400, "invalid_json", "request JSON is invalid")
        rescue ex : Invalid
          status = error(context, 400, "invalid", ex.message || "invalid request")
        rescue ex : Unauthorized
          status = error(context, 401, "unauthorized", ex.message || "unauthorized")
        rescue ex : NotFound
          status = error(context, 404, "not_found", ex.message || "not found")
        rescue ex : Conflict
          status = error(context, 409, "conflict", ex.message || "conflict")
        rescue ex : Expired
          status = error(context, 410, "expired", ex.message || "expired")
        rescue ex : RotationLimited
          context.response.headers["Retry-After"] = ex.retry_after_seconds.to_s
          status = json(
            context, 429,
            RotationLimitEvidence.new(
              "rotation_limited", ex.retry_after_seconds
            ).to_json
          )
        rescue ex : Unavailable
          status = error(context, 503, "unavailable", ex.message || "unavailable")
        rescue ex
          STDERR.puts({
            event:      "request_failed",
            error:      ex.class.name,
            request_id: request_id(context),
          }.to_json)
          status = error(context, 500, "internal", "internal server error")
        ensure
          STDERR.puts({
            event: "request", request_id: request_id(context), method: context.request.method,
            path: safe_log_path(context.request.path), status: status,
            duration_ms: (Time.instant - started).total_milliseconds.round.to_i,
          }.to_json)
        end
      end
    end

    def close : Nil
      database.close
    end

    private def route(context : HTTP::Server::Context) : Int32
      request = context.request
      path = request.path
      if path.starts_with?("/v1/")
        return incompatible_protocol(context) unless compatible_protocol?(request)
      end
      case {request.method, path}
      when {"GET", "/healthz"}, {"HEAD", "/healthz"}
        json(context, 200, %({"status":"ok"}))
      when {"GET", "/readyz"}, {"HEAD", "/readyz"}
        database.db.scalar("SELECT 1")
        json(context, 200, %({"status":"ready"}))
      when {"GET", "/metrics"}, {"HEAD", "/metrics"}
        context.response.headers["Cache-Control"] = "no-store"
        write_body(
          context, 200, "text/plain; version=0.0.4; charset=utf-8",
          metrics.render(store, handoffs)
        )
      when {"POST", "/v1/join"}
        claim_ship(context)
      when {"POST", "/v1/ships/inspect"}
        json(context, 200, store.inspect_ship(parse_body(context, ShipInspection)))
      when {"POST", "/v1/transmissions"}
        accept_transmission(context)
      when {"POST", "/v1/hails"}
        accept_hail(context)
      when {"POST", "/v1/radio/wait"}
        radio_wait(context)
      when {"POST", "/v1/transmissions/ack"}
        acknowledgement = parse_body(context, TransmissionAck)
        latency = if prepared = handoffs.prepared_for_ack(
                       acknowledgement.transmission_id, acknowledgement.auth.ship
                     )
                    store.verify_ack(acknowledgement)
                    handoffs.complete(acknowledgement.transmission_id)
                    Math.max(Time.utc.to_unix - prepared.accepted_at, 0_i64)
                  else
                    store.acknowledge(acknowledgement)
                  end
        metrics.transmission("acknowledged")
        latency.try { |seconds| metrics.acknowledgement_latency(seconds) }
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/hails/ack"}
        store.acknowledge_hail(parse_body(context, HailAck))
        metrics.hail("collected")
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/relationships/close"}
        closure = parse_body(context, RelationshipClose)
        store.close_relationship(closure)
        handoffs.notify(closure.auth.ship)
        closure.retained_ships.each { |ship| handoffs.notify(ship) }
        json(context, 200, %({"state":"retuning"}))
      when {"POST", "/v1/relationships/retune/ack"}
        store.acknowledge_retune(parse_body(context, RetuneAck))
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/relationships/allow"}
        store.allow_relationship(parse_body(context, RelationshipAllow))
        metrics.hail("allowed")
        json(context, 200, %({"state":"active"}))
      when {"POST", "/v1/owners/rotate"}
        store.rotate_owner(parse_body(context, OwnerRotation))
        json(context, 200, %({"state":"rotated"}))
      when {"POST", "/v1/ships/change"}
        store.ship_change(parse_body(context, ShipChange))
        json(context, 200, %({"state":"updated"}))
      else
        return error(context, 404, "not_found", "API route not found") if path.starts_with?("/v1/")
        public_route(context)
      end
    end

    private def claim_ship(context : HTTP::Server::Context) : Int32
      counted = false
      prepared = store.prepare_claim(parse_body(context, ShipClaim))
      if retry_after = @registration_window.admit(REGISTRATION_WINDOW_KEY)
        metrics.registration("rate_limited")
        counted = true
        context.response.headers["Retry-After"] = retry_after.to_s
        return error(
          context, 429, "registration_limited",
          "relay is receiving too many registrations"
        )
      end
      store.claim(prepared)
      metrics.registration("accepted")
      counted = true
      json(context, 201, %({"state":"claimed"}))
    rescue ex : Conflict
      metrics.registration("conflict") unless counted
      raise ex
    rescue ex : Unavailable
      metrics.registration("capacity") unless counted
      raise ex
    rescue ex : JSON::ParseException | JSON::SerializableError | Invalid | Unauthorized
      metrics.registration("invalid") unless counted
      raise ex
    end

    private def accept_transmission(context : HTTP::Server::Context) : Int32
      acceptance_at = Time.instant + ACCEPTANCE_TARGET
      outcome = "rejected"
      counted = false
      envelope = parse_body(context, SignedRelayEnvelope)
      if prepared = store.prepare(envelope)
        if submission_window.allow?(envelope.sender_ship) && store.deliverable?(prepared)
          remaining = acceptance_at - Time.instant
          if remaining > Time::Span.zero && handoffs.deliver(prepared, remaining)
            outcome = "direct"
          elsif store.persist(prepared)
            handoffs.notify(envelope.recipient_ship)
            outcome = "queued"
          end
        end
      end
      remaining = acceptance_at - Time.instant
      sleep remaining if remaining > Time::Span.zero
      metrics.transmission(outcome)
      if outcome != "rejected"
        metrics.transmission_bytes(outcome, prepared.not_nil!.ciphertext.size.to_i64)
      end
      counted = true
      json(context, 202, %({"state":"accepted"}))
    rescue ex
      metrics.transmission("rejected") unless counted
      raise ex
    end

    private def accept_hail(context : HTTP::Server::Context) : Int32
      acceptance_at = Time.instant + ACCEPTANCE_TARGET
      outcome = "rejected"
      counted = false
      hail = parse_body(context, Hail)
      if prepared = store.prepare_hail(hail)
        if hail_window.allow?(hail.sender_ship) && store.persist_hail(prepared)
          handoffs.notify(hail.recipient_ship)
          outcome = "accepted"
        end
      end
      remaining = acceptance_at - Time.instant
      sleep remaining if remaining > Time::Span.zero
      metrics.hail(outcome)
      counted = true
      json(context, 202, %({"state":"accepted"}))
    rescue ex
      metrics.hail("rejected") unless counted
      raise ex
    end

    private def radio_wait(context : HTTP::Server::Context) : Int32
      request = parse_body(context, RadioWaitRequest)
      response = wait(request)
      outcome = if response.envelope
                  "transmission"
                elsif response.hail
                  "hail"
                elsif !response.contact_updates.empty?
                  "contact_update"
                else
                  "timeout"
                end
      status = json(context, 200, response.to_json)
      metrics.radio_wait(outcome)
      status
    rescue ex : IO::Error
      metrics.radio_wait("disconnect")
      raise ex
    rescue ex
      metrics.radio_wait("error")
      raise ex
    end

    private def compatible_protocol?(request : HTTP::Request) : Bool
      request.headers["X-Tinrelay-Protocol"]?.try(&.to_i?) == PROTOCOL
    end

    private def incompatible_protocol(context : HTTP::Server::Context) : Int32
      supplied = context.request.headers["X-Tinrelay-Protocol"]?.try(&.to_i?) || 0
      relation = supplied < PROTOCOL ? "older" : "newer"
      json(context, 426, {
        error: "protocol_incompatible", client_protocol: supplied,
        supported_min: PROTOCOL, supported_max: PROTOCOL, relation: relation,
      }.to_json)
    end

    private def wait(request : RadioWaitRequest) : RadioWaitResponse
      deadline = Time.instant + request.hold_seconds.seconds
      response = store.wait_once(request)
      return response unless response.empty? && request.hold_seconds > 0

      waiter = handoffs.park(request.auth.ship, request.auth.radio_generation)
      begin
        loop do
          # A second read after parking closes the race between the first read
          # and waiter registration without periodically polling SQLite.
          response = store.wait_once(request)
          return response unless response.empty?
          remaining = deadline - Time.instant
          return response if remaining <= Time::Span.zero
          case event = handoffs.wait(waiter, remaining)
          when SignedRelayEnvelope
            envelope = event
            return RadioWaitResponse.new(envelope: envelope)
          when :timeout
            return response
          end
        end
      ensure
        handoffs.release(request.auth.ship, waiter)
      end
    end

    private def parse_body(context, type : T.class) : T forall T
      content_length = context.request.headers["Content-Length"]?.try(&.to_i64?)
      if content_length && content_length > MAX_REQUEST_BYTES
        raise Invalid.new("request body exceeds #{MAX_REQUEST_BYTES} bytes")
      end
      body = read_limited(context.request.body)
      type.from_json(body)
    end

    private def read_limited(input : IO?) : String
      return "" unless input
      output = IO::Memory.new
      buffer = Bytes.new(8192)
      total = 0
      loop do
        read = input.read(buffer)
        break if read == 0
        total += read
        if total > MAX_REQUEST_BYTES
          raise Invalid.new("request body exceeds #{MAX_REQUEST_BYTES} bytes")
        end
        output.write(buffer[0, read])
      end
      output.to_s
    end

    private def public_route(context : HTTP::Server::Context) : Int32
      request = context.request
      page = bootstrap_page
      return public_not_found(context, page) unless request.method.in?({"GET", "HEAD"})
      path = request.path
      return homepage(context, page, path == "/index.md") if path.in?({"/", "/index.md"})
      if path == "/llms.txt"
        return public_text(context, page.agent_map, "text/plain; charset=utf-8")
      end
      if path == "/robots.txt"
        return public_text(
          context,
          page.static("robots.txt"),
          "text/plain; charset=utf-8"
        )
      end
      if path == "/sitemap.xml"
        return public_text(
          context,
          page.sitemap,
          "application/xml; charset=utf-8"
        )
      end
      if name = public_asset_name(path)
        return public_asset(context, page, name)
      end

      if line = line_route(path)
        return bootstrap(
          context, page, line[:coordinate], line[:journey], line[:action],
          explicit_markdown: line[:explicit_markdown]
        )
      end
      public_not_found(context, page)
    end

    private def homepage(context : HTTP::Server::Context,
                         page : BootstrapPage,
                         explicit_markdown : Bool) : Int32
      markdown = page.homepage
      alternate = "/index.md"
      wants_markdown = explicit_markdown || markdown_requested?(context.request)
      body = wants_markdown ? markdown : page.html(
        markdown, false, alternate, "home", handoffs.waiting_count
      )
      context.response.headers["Cache-Control"] = "no-store"
      context.response.headers["Vary"] = "Accept"
      context.response.headers["Referrer-Policy"] = "no-referrer"
      context.response.headers["Content-Security-Policy"] = content_security_policy(true)
      context.response.headers["Link"] = alternate_link(page, alternate)
      write_body(
        context, 200,
        wants_markdown ? "text/markdown; charset=utf-8" : "text/html; charset=utf-8",
        body
      )
    end

    private def bootstrap(context : HTTP::Server::Context, page : BootstrapPage,
                          coordinate : String?, journey : String?, action : String?,
                          explicit_markdown : Bool) : Int32
      markdown = if action == BootstrapPage::FLIGHT_PLAN_PAGE
                   page.flight_plan(coordinate)
                 else
                   page.markdown(
                     coordinate, action, journey,
                     repeater_origin: request_origin(context.request)
                   )
                 end
      directed = !coordinate.nil?
      private_page = directed || !action.nil?
      alternate = line_markdown_path(coordinate, journey, action)
      wants_markdown = explicit_markdown || markdown_requested?(context.request)
      page_key = action || "meet"
      body = wants_markdown ? markdown : page.html(
        markdown, private_page, alternate, page_key, handoffs.waiting_count
      )
      content_type = wants_markdown ? "text/markdown; charset=utf-8" : "text/html; charset=utf-8"
      context.response.headers["Cache-Control"] = "no-store"
      context.response.headers["Vary"] = "Accept"
      context.response.headers["Referrer-Policy"] = "no-referrer"
      context.response.headers["Content-Security-Policy"] = content_security_policy
      context.response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive" if private_page
      context.response.headers["Link"] = alternate_link(page, alternate)
      write_body(context, 200, content_type, body)
    end

    private def public_not_found(context : HTTP::Server::Context,
                                 page : BootstrapPage) : Int32
      markdown = page.not_found
      wants_markdown = markdown_requested?(context.request)
      body = wants_markdown ? markdown : page.html(
        markdown, true, "/line/index.md", "not-found", handoffs.waiting_count
      )
      context.response.headers["Cache-Control"] = "no-store"
      context.response.headers["Vary"] = "Accept"
      context.response.headers["Referrer-Policy"] = "no-referrer"
      context.response.headers["Content-Security-Policy"] = content_security_policy
      context.response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive"
      write_body(
        context, 404,
        wants_markdown ? "text/markdown; charset=utf-8" : "text/html; charset=utf-8",
        body
      )
    end

    private def public_text(context : HTTP::Server::Context, body : String,
                            content_type : String) : Int32
      context.response.headers["Cache-Control"] = "public, max-age=300"
      write_body(context, 200, content_type, body)
    end

    private def public_asset(context : HTTP::Server::Context,
                             page : BootstrapPage, name : String) : Int32
      asset = page.asset(name)
      context.response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
      context.response.headers["X-Content-Type-Options"] = "nosniff"
      write_body(
        context, 200, asset[:content_type], asset[:body]
      )
    end

    private def public_asset_name(path : String) : String?
      prefix = "/assets/tinrelay/"
      return nil unless path.starts_with?(prefix)
      name = path[prefix.bytesize..]
      name.empty? ? nil : name
    end

    private def write_body(context : HTTP::Server::Context, status : Int32,
                           content_type : String, body : String) : Int32
      context.response.status_code = status
      context.response.content_type = content_type
      context.response.content_length = body.bytesize
      context.response.print(body) unless context.request.method == "HEAD"
      status
    end

    private def json(context, status : Int32, body : String) : Int32
      context.response.status_code = status
      context.response.content_type = "application/json; charset=utf-8"
      context.response.headers["Cache-Control"] = "no-store"
      context.response.content_length = body.bytesize
      context.response.print(body) unless context.request.method == "HEAD"
      status
    end

    private def error(context, status : Int32, code : String, message : String) : Int32
      json(context, status, {error: code, message: message}.to_json)
    end

    private def request_id(context) : String
      context.request.headers["X-Request-ID"]? || "local-#{Process.pid}"
    end

    private def safe_log_path(path : String) : String
      directed_line_path?(path) ? "/:coordinate" : path
    end

    private def line_route(path : String) : NamedTuple(
      coordinate: String?,
      journey: String?,
      action: String?,
      explicit_markdown: Bool,
    )?
      return nil unless path.starts_with?('/') && path.size > 1 && !path.ends_with?('/')
      segments = path[1..].split('/')
      explicit_markdown = segments.last? == "index.md"
      segments.pop if explicit_markdown
      return nil if segments.empty? || segments.any?(&.empty?)

      first = decode_path!(segments.shift)
      coordinate = if first == "line"
                     nil
                   else
                     Names.coordinate!(first)
                     first
                   end

      if segments.empty?
        return {
          coordinate:        coordinate,
          journey:           nil,
          action:            nil,
          explicit_markdown: explicit_markdown,
        }
      end
      if segments.size == 1 && segments[0] == BootstrapPage::FLIGHT_PLAN_PAGE
        return {
          coordinate:        coordinate,
          journey:           nil,
          action:            segments[0],
          explicit_markdown: explicit_markdown,
        }
      end

      return nil unless segments.size.in?(1..2)
      journey = segments[0]
      return nil unless BootstrapPage::JOURNEYS.includes?(journey)
      action = segments[1]? || journey
      return nil unless BootstrapPage.action_allowed?(journey, action)
      {
        coordinate:        coordinate,
        journey:           journey,
        action:            action,
        explicit_markdown: explicit_markdown,
      }
    rescue Invalid
      nil
    end

    private def line_markdown_path(
      coordinate : String?,
      journey : String?,
      action : String?,
    ) : String
      path = coordinate ? "/#{URI.encode_path_segment(coordinate)}" : "/line"
      if action == BootstrapPage::FLIGHT_PLAN_PAGE
        return "#{path}/#{BootstrapPage::FLIGHT_PLAN_PAGE}/index.md"
      end
      return "#{path}/index.md" unless journey
      path = "#{path}/#{journey}"
      path = "#{path}/#{action}" if action && action != journey
      "#{path}/index.md"
    end

    private def content_security_policy(allow_script : Bool = false) : String
      "default-src 'none'; " +
        "style-src 'self'; " +
        "img-src 'self'; " +
        "font-src 'self'; " +
        (allow_script ? "script-src 'self'; " : "") +
        "base-uri 'none'; " +
        "form-action 'none'"
    end

    private def alternate_link(page : BootstrapPage, alternate : String) : String
      %(<#{page.public_url(alternate)}>; rel="alternate"; type="text/markdown", ) +
        %(<#{page.public_url("/llms.txt")}>; rel="describedby")
    end

    private def load_runtime_snapshot(allow_missing_default : Bool) : RuntimeSnapshot
      candidate = TinrelaydConfig.load(
        config.configuration_path, allow_missing_default
      )
      site = candidate.try(&.site)
      art_manifest = ArtManifest.load(
        site.try(&.art_manifest_path), BootstrapPage::PAGE_KEYS
      )
      page = BootstrapPage.new(
        config.bootstrap_template, config.source_repository, art_manifest,
        site_name: site.try(&.site_name) || BootstrapPage::DEFAULT_SITE_NAME,
        site_base_url: site.try(&.base_url) || BootstrapPage::DEFAULT_SITE_BASE_URL,
        wordmark: site.try(&.wordmark) || BootstrapPage::DEFAULT_WORDMARK
      )
      RuntimeSnapshot.new(
        page,
        candidate.try(&.registration_allowances) || RegistrationAllowances.new,
        candidate.try(&.registration_deny_cidrs) || [] of IPNetwork,
        candidate.try(&.client_address_policy) ||
        ClientAddressPolicy.new("direct", [] of String)
      )
    end

    private def directed_line_path?(path : String) : Bool
      line_route(path).try { |line| !line[:coordinate].nil? } || false
    end

    private def markdown_requested?(request : HTTP::Request) : Bool
      request.headers["Accept"]?.try do |header|
        header.split(',').any? do |entry|
          media, *parameters = entry.split(';').map(&.strip)
          quality_parameter = parameters.find(&.starts_with?("q="))
          quality = quality_parameter ? quality_parameter[2..].to_f? || 0.0 : 1.0
          media == "text/markdown" && quality > 0.0
        end
      end || false
    end

    private def request_origin(request : HTTP::Request) : String
      scheme = request.headers["X-Forwarded-Proto"]?
        .try(&.split(',').first.strip) || "http"
      raise Invalid.new("public request scheme is invalid") unless scheme.in?({"http", "https"})
      authority = request.headers["Host"]? ||
                  raise Invalid.new("public request host is missing")
      unless authority.each_char.all? do |character|
               character.ascii_alphanumeric? || character.in?({'.', '-', ':', '[', ']'})
             end
        raise Invalid.new("public request origin is invalid")
      end
      uri = URI.parse("#{scheme}://#{authority}")
      unless uri.scheme == scheme && uri.host && uri.user.nil? &&
             uri.password.nil? && uri.path.empty? && uri.query.nil? &&
             uri.fragment.nil?
        raise Invalid.new("public request origin is invalid")
      end
      "#{scheme}://#{uri.authority}"
    rescue URI::Error
      raise Invalid.new("public request origin is invalid")
    end

    private def decode_path!(value : String) : String
      URI.decode(value)
    rescue URI::Error
      raise Invalid.new("URL path encoding is invalid")
    end
  end
end
