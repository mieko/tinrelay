require "uri"

module Tinrelay
  class ServerConfig
    getter bind : String
    getter port : Int32
    getter database_path : String
    getter bootstrap_token_hash : Bytes?
    getter bootstrap_template : String
    getter source_repository : String
    getter database_connections : Int32
    getter art_manifest_path : String?

    def initialize(@bind = "127.0.0.1", @port = 8787,
                   @database_path = "tinrelay.db",
                   @bootstrap_token_hash = nil,
                   @bootstrap_template = "templates/common-bootstrap.md",
                   @source_repository = "https://github.com/mieko/tinrelay",
                   @database_connections = System.cpu_count,
                   @art_manifest_path = nil)
    end
  end

  class API
    MAX_REQUEST_BYTES = 64 * 1024
    ACCEPTANCE_TARGET = 250.milliseconds
    WAIT_SLICE        = 250.milliseconds

    getter config : ServerConfig
    getter database : Database
    getter store : Store
    getter handoffs : DirectHandoff
    getter submission_window : SubmissionWindow
    getter hail_window : SubmissionWindow
    getter bootstrap_page : BootstrapPage

    def initialize(@config)
      @database = Database.new(config.database_path, config.database_connections)
      @store = Store.new(database)
      @handoffs = DirectHandoff.new
      @submission_window = SubmissionWindow.new
      @hail_window = SubmissionWindow.new(Store::MAX_HAILS_PER_DAY, 24 * 60 * 60)
      art_manifest = ArtManifest.load(
        config.art_manifest_path, BootstrapPage::PAGE_KEYS
      )
      @bootstrap_page = BootstrapPage.new(
        config.bootstrap_template, config.source_repository, art_manifest
      )
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
        rescue ex : Unavailable
          status = error(context, 503, "unavailable", ex.message || "unavailable")
        rescue ex
          STDERR.puts({event: "request_failed", error: ex.class.name, request_id: request_id(context)}.to_json)
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
      when {"POST", "/v1/bootstrap/claim"}
        claim = parse_body(context, ShipClaim)
        verify_bootstrap_token!(claim.bootstrap_token)
        store.claim(claim, allow_bootstrap: true)
        json(context, 201, %({"state":"claimed"}))
      when {"POST", "/v1/join"}
        claim = parse_body(context, ShipClaim)
        store.claim(claim)
        json(context, 201, %({"state":"claimed"}))
      when {"POST", "/v1/invitations"}
        store.create_invitation(parse_body(context, InvitationCreate))
        json(context, 201, %({"state":"created"}))
      when {"POST", "/v1/invitations/revoke"}
        store.revoke_invitation(parse_body(context, InvitationRevoke))
        json(context, 200, %({"state":"revoked"}))
      when {"POST", "/v1/invitations/accept"}
        json(context, 200, store.accept_invitation(parse_body(context, InvitationAccept)))
      when {"POST", "/v1/ships/inspect"}
        json(context, 200, store.inspect_ship(parse_body(context, ShipInspection)))
      when {"POST", "/v1/transmissions"}
        acceptance_at = Time.instant + ACCEPTANCE_TARGET
        envelope = parse_body(context, SignedRelayEnvelope)
        if prepared = store.prepare(envelope)
          if submission_window.allow?(envelope.sender_ship)
            if store.deliverable?(prepared)
              remaining = acceptance_at - Time.instant
              delivered = remaining > Time::Span.zero && handoffs.deliver(prepared, remaining)
              store.persist(prepared) unless delivered
            end
          end
        end
        remaining = acceptance_at - Time.instant
        sleep remaining if remaining > Time::Span.zero
        json(context, 202, %({"state":"accepted"}))
      when {"POST", "/v1/hails"}
        acceptance_at = Time.instant + ACCEPTANCE_TARGET
        hail = parse_body(context, Hail)
        if prepared = store.prepare_hail(hail)
          store.persist_hail(prepared) if hail_window.allow?(hail.sender_ship)
        end
        remaining = acceptance_at - Time.instant
        sleep remaining if remaining > Time::Span.zero
        json(context, 202, %({"state":"accepted"}))
      when {"POST", "/v1/radio/wait"}
        request = parse_body(context, RadioWaitRequest)
        json(context, 200, wait(request).to_json)
      when {"POST", "/v1/transmissions/ack"}
        acknowledgement = parse_body(context, TransmissionAck)
        if prepared = handoffs.prepared_for_ack(
             acknowledgement.transmission_id, acknowledgement.auth.ship
           )
          store.verify_ack(acknowledgement)
          handoffs.complete(acknowledgement.transmission_id)
        else
          store.acknowledge(acknowledgement)
        end
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/hails/ack"}
        store.acknowledge_hail(parse_body(context, HailAck))
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/relationships/close"}
        store.close_relationship(parse_body(context, RelationshipClose))
        json(context, 200, %({"state":"retuning"}))
      when {"POST", "/v1/relationships/retune/ack"}
        store.acknowledge_retune(parse_body(context, RetuneAck))
        json(context, 200, %({"state":"acknowledged"}))
      when {"POST", "/v1/relationships/allow"}
        store.allow_relationship(parse_body(context, RelationshipAllow))
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
      loop do
        response = store.wait_once(request)
        return response unless response.empty?
        remaining = deadline - Time.instant
        return response if remaining <= Time::Span.zero
        slice = remaining < WAIT_SLICE ? remaining : WAIT_SLICE
        if envelope = handoffs.wait(request.auth.ship, slice)
          return RadioWaitResponse.new(envelope: envelope)
        end
      end
    end

    private def parse_body(context, type : T.class) : T forall T
      content_length = context.request.headers["Content-Length"]?.try(&.to_i64?)
      raise Invalid.new("request body exceeds #{MAX_REQUEST_BYTES} bytes") if content_length && content_length > MAX_REQUEST_BYTES
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
        raise Invalid.new("request body exceeds #{MAX_REQUEST_BYTES} bytes") if total > MAX_REQUEST_BYTES
        output.write(buffer[0, read])
      end
      output.to_s
    end

    private def verify_bootstrap_token!(supplied : String?) : Nil
      expected = config.bootstrap_token_hash || raise Unauthorized.new("bootstrap claim is disabled")
      token = supplied || raise Unauthorized.new("bootstrap token is required")
      actual = Digest::SHA256.digest(token)
      raise Unauthorized.new("bootstrap token is invalid") unless Crypto.constant_time_equal?(expected, actual)
    end

    private def public_route(context : HTTP::Server::Context) : Int32
      request = context.request
      return public_not_found(context) unless request.method.in?({"GET", "HEAD"})
      path = request.path
      return redirect(context, "/meet") if path == "/meet/"
      return homepage(context, path == "/index.md") if path.in?({"/", "/index.md"})
      return public_text(context, bootstrap_page.agent_map, "text/plain; charset=utf-8") if path == "/llms.txt"
      return public_text(context, bootstrap_page.static("robots.txt"), "text/plain; charset=utf-8") if path == "/robots.txt"
      return public_text(context, bootstrap_page.static("sitemap.xml"), "application/xml; charset=utf-8") if path == "/sitemap.xml"
      if name = public_asset_name(path)
        return public_asset(context, name)
      end

      if meet = meet_route(path)
        return bootstrap(
          context, meet[:coordinate], meet[:journey], meet[:action],
          explicit_markdown: meet[:explicit_markdown]
        )
      end
      public_not_found(context)
    end

    private def homepage(context : HTTP::Server::Context,
                         explicit_markdown : Bool) : Int32
      markdown = bootstrap_page.static("home.md")
      alternate = "/index.md"
      wants_markdown = explicit_markdown || markdown_requested?(context.request)
      body = wants_markdown ? markdown : bootstrap_page.html(
        markdown, false, alternate, "home"
      )
      context.response.headers["Cache-Control"] = "no-store"
      context.response.headers["Vary"] = "Accept"
      context.response.headers["Referrer-Policy"] = "no-referrer"
      context.response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'"
      context.response.headers["Link"] = %(<#{alternate}>; rel="alternate"; type="text/markdown", </llms.txt>; rel="describedby")
      write_body(
        context, 200,
        wants_markdown ? "text/markdown; charset=utf-8" : "text/html; charset=utf-8",
        body
      )
    end

    private def bootstrap(context : HTTP::Server::Context, coordinate : String?, journey : String?,
                          action : String?,
                          explicit_markdown : Bool) : Int32
      markdown = bootstrap_page.markdown(coordinate, action, journey)
      directed = !coordinate.nil?
      private_page = directed || !action.nil?
      alternate = meet_markdown_path(coordinate, journey, action)
      wants_markdown = explicit_markdown || markdown_requested?(context.request)
      page = action || "meet"
      body = wants_markdown ? markdown : bootstrap_page.html(
        markdown, private_page, alternate, page
      )
      content_type = wants_markdown ? "text/markdown; charset=utf-8" : "text/html; charset=utf-8"
      context.response.headers["Cache-Control"] = "no-store"
      context.response.headers["Vary"] = "Accept"
      context.response.headers["Referrer-Policy"] = "no-referrer"
      context.response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'"
      context.response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive" if private_page
      context.response.headers["Link"] = %(<#{alternate}>; rel="alternate"; type="text/markdown", </llms.txt>; rel="describedby")
      write_body(context, 200, content_type, body)
    end

    private def public_not_found(context : HTTP::Server::Context) : Int32
      markdown = bootstrap_page.static("not-found.md")
      wants_markdown = markdown_requested?(context.request)
      body = wants_markdown ? markdown : bootstrap_page.html(
        markdown, true, "/meet/index.md", "not-found"
      )
      context.response.headers["Cache-Control"] = "no-store"
      context.response.headers["Vary"] = "Accept"
      context.response.headers["Referrer-Policy"] = "no-referrer"
      context.response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'"
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

    private def public_asset(context : HTTP::Server::Context, name : String) : Int32
      context.response.headers["Cache-Control"] = "public, max-age=86400"
      context.response.headers["X-Content-Type-Options"] = "nosniff"
      write_body(
        context, 200, "text/css; charset=utf-8", bootstrap_page.asset(name)
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

    private def redirect(context, location : String) : Int32
      context.response.status_code = 308
      context.response.headers["Location"] = location
      context.response.headers["Cache-Control"] = "no-store"
      308
    end

    private def request_id(context) : String
      context.request.headers["X-Request-ID"]? || "local-#{Process.pid}"
    end

    private def safe_log_path(path : String) : String
      directed_meet_path?(path) ? "/meet/:coordinate" : path
    end

    private def meet_route(path : String) : NamedTuple(coordinate: String?, journey: String?, action: String?, explicit_markdown: Bool)?
      return {coordinate: nil, journey: nil, action: nil, explicit_markdown: false} if path == "/meet"
      return {coordinate: nil, journey: nil, action: nil, explicit_markdown: true} if path == "/meet/index.md"

      explicit_markdown = path.starts_with?("/meet/index.md/")
      remainder = if explicit_markdown
                    path[15..]
                  elsif path.starts_with?("/meet/")
                    path[6..]
                  else
                    return nil
                  end
      return nil if remainder.empty? || remainder.ends_with?('/')
      segments = remainder.split('/')

      decoded = segments.map { |segment| decode_path!(segment) }
      first = decoded[0]
      if BootstrapPage::JOURNEYS.includes?(first)
        return nil unless decoded.size.in?(1..2)
        action = decoded[1]? || first
        return nil unless meet_action_allowed?(first, action)
        return {coordinate: nil, journey: first, action: action, explicit_markdown: explicit_markdown}
      end

      return nil unless decoded.size.in?(1..3)
      Names.coordinate!(first)
      coordinate = first
      return {coordinate: coordinate, journey: nil, action: nil, explicit_markdown: explicit_markdown} if decoded.size == 1
      journey = decoded[1]
      return nil unless BootstrapPage::JOURNEYS.includes?(journey)
      action = decoded[2]? || journey
      return nil unless meet_action_allowed?(journey, action)
      {coordinate: coordinate, journey: journey, action: action, explicit_markdown: explicit_markdown}
    rescue Invalid
      nil
    end

    private def meet_markdown_path(coordinate : String?, journey : String?, action : String?) : String
      path = coordinate ? "/meet/index.md/#{URI.encode_path_segment(coordinate)}" : "/meet/index.md"
      return path unless journey
      path = "#{path}/#{journey}"
      action && action != journey ? "#{path}/#{action}" : path
    end

    private def meet_action_allowed?(journey : String, action : String) : Bool
      BootstrapPage.action_allowed?(journey, action)
    end

    private def directed_meet_path?(path : String) : Bool
      remainder = if path.starts_with?("/meet/index.md/")
                    path[15..]
                  elsif path.starts_with?("/meet/")
                    path[6..]
                  else
                    return false
                  end
      first = remainder.split('/').first?
      return false unless first
      decoded = decode_path!(first)
      return false if BootstrapPage::JOURNEYS.includes?(decoded)
      Names.coordinate!(decoded)
      true
    rescue Invalid
      false
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

    private def decode_path!(value : String) : String
      URI.decode(value)
    rescue URI::Error
      raise Invalid.new("URL path encoding is invalid")
    end
  end
end
