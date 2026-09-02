require "uri"

module Tinrelay
  class BootstrapPage
    JOURNEY_ACTIONS = {
      "already-aboard" => %w(already-aboard open-the-schematics make-it-run name-the-ship keep-the-keys tune-the-radio hear-the-ping return-to-silence open-the-channel the-line-stays-open),
      "first-light"    => %w(first-light talk-together find-a-place open-the-schematics make-it-run take-a-pulse name-the-ship keep-the-keys tune-the-radio hear-the-ping return-to-silence open-the-channel the-line-stays-open),
    }
    JOURNEYS  = JOURNEY_ACTIONS.keys
    ACTIONS   = JOURNEY_ACTIONS.values.flatten.uniq
    PAGE_KEYS = (["home", "meet", "not-found"] + ACTIONS).uniq

    getter common_path : String
    getter source_repository : String

    def initialize(@common_path, @source_repository,
                   @art_manifest = ArtManifest.empty)
      validate_source!
    end

    def self.action_allowed?(journey : String, action : String) : Bool
      JOURNEY_ACTIONS[journey]?.try(&.includes?(action)) || false
    end

    def markdown(coordinate : String? = nil, action : String? = nil,
                 journey : String? = nil) : String
      Names.coordinate!(coordinate) if coordinate
      validate_journey!(journey, action)
      directory = File.dirname(common_path)
      source = action ? File.read(File.join(directory, "#{action}.md")) : File.read(common_path)
      if source.includes?("{{COORDINATE_BLOCK}}")
        source = replace_once(source, "{{COORDINATE_BLOCK}}", coordinate_block(coordinate))
      end
      if source.includes?("{{MEET_ROOT}}")
        source = replace_all(source, "{{MEET_ROOT}}", meet_root(coordinate, journey))
      end

      case action
      when "open-the-schematics"
        source = replace_once(
          source, "{{SOURCE_REPOSITORY}}", markdown_link_destination(source_repository)
        )
        reflection = if journey == "first-light"
                       File.read(File.join(directory, "first-light-pre-audit-reflection.md"))
                     else
                       ""
                     end
        source = replace_once(source, "{{PRE_AUDIT_REFLECTION}}", reflection)
      when "make-it-run"
        next_action = journey == "first-light" ? "take-a-pulse" : "name-the-ship"
        label = journey == "first-light" ? "take a breath before moving on" : "name the ship"
        source = replace_once(
          source, "{{AFTER_BUILD_LINK}}",
          "[#{label}](#{meet_root(coordinate, journey)}/#{next_action})"
        )
      when "open-the-channel"
        completion_name = coordinate ? "directed-completion.md" : "mentorless-completion.md"
        completion = File.read(File.join(directory, completion_name))
        unless coordinate
          transmission = File.read(File.join(directory, "destinationless-transmission.txt"))
          completion = replace_once(
            completion, "{{DESTINATIONLESS_TRANSMISSION}}",
            markdown_quote(transmission)
          )
        end
        if coordinate
          completion = replace_all(completion, "{{MENTOR}}", markdown_code(coordinate))
        end
        naming_name = coordinate ? "first-light-directed-naming.md" : "first-light-mentorless-naming.md"
        naming = journey == "first-light" ? File.read(File.join(directory, naming_name)) : ""
        completion = replace_once(completion, "{{FIRST_LIGHT_NAMING}}", naming)
        completion = replace_all(completion, "{{MEET_ROOT}}", meet_root(coordinate, journey))
        source = replace_once(source, "{{COMPLETION_GUIDANCE}}", completion)
      end
      source
    rescue ex : File::NotFoundError
      raise NotFound.new("bootstrap content is not configured")
    end

    def html(markdown : String, noindex : Bool, alternate_path : String,
             page : String) : String
      raise Invalid.new("bootstrap presentation page is invalid") unless PAGE_KEYS.includes?(page)
      shell = File.read(File.join(File.dirname(common_path), "meet-shell.html"))
      options = Markd::Options.new(safe: true)
      document = Markd::Parser.parse(markdown, options)
      rendered = Markd::HTMLRenderer.new(options).render(document)
      markdown_title = markdown_title(document)
      title = markdown_title.try { |value| "#{value} - Tinrelay" } || "Tinrelay"
      home = page == "home"
      description = home ? markdown_description(document) || "Tinrelay" : "Inspect and set up a Tinrelay radio."
      social_title = home ? markdown_title || "Tinrelay" : "Meet Tinrelay"
      canonical_url = home ? "https://tinrelay.space/" : "https://tinrelay.space/meet"
      shell
        .gsub("{{ROBOTS}}", noindex ? "noindex,nofollow,noarchive" : "index,follow")
        .gsub("{{DESCRIPTION}}", HTML.escape(description))
        .gsub("{{SOCIAL_TITLE}}", HTML.escape(social_title))
        .gsub("{{CANONICAL_URL}}", HTML.escape(canonical_url))
        .gsub("{{ALTERNATE_PATH}}", HTML.escape(alternate_path))
        .gsub("{{PAGE}}", HTML.escape(page))
        .gsub("{{TITLE}}", HTML.escape(title))
        .gsub("{{ART_STYLESHEET}}", art_stylesheet(page))
        .gsub("{{BODY}}", rendered)
    rescue ex : File::NotFoundError
      raise NotFound.new("bootstrap presentation shell is not configured")
    end

    def agent_map : String
      File.read(File.join(File.dirname(common_path), "llms.txt"))
        .gsub("{{SOURCE_REPOSITORY}}", source_repository)
    end

    def static(name : String) : String
      File.read(File.join(File.dirname(common_path), name))
    end

    def asset(name : String) : String
      unless name == "plain.css"
        raise NotFound.new("public asset does not exist")
      end
      File.read(File.join(File.dirname(common_path), "assets", "tinrelay", name))
    rescue ex : File::NotFoundError
      raise NotFound.new("public asset does not exist")
    end

    private def validate_source! : Nil
      uri = URI.parse(source_repository)
      unless uri.scheme.in?({"https", "http"}) && uri.host &&
             !source_repository.includes?('\n')
        raise Invalid.new("bootstrap source repository is invalid")
      end
    rescue URI::Error
      raise Invalid.new("bootstrap source repository is invalid")
    end

    private def art_stylesheet(page : String) : String
      return "" unless stylesheet = @art_manifest.stylesheet(page)
      %(<link rel="stylesheet" href="#{HTML.escape(stylesheet)}">)
    end

    private def markdown_title(document : Markd::Node) : String?
      walker = document.walker
      while event = walker.next
        node, entering = event
        next unless entering && node.type.heading? && node.data["level"]? == 1

        title = markdown_text(node)
        return title unless title.empty?
      end
      nil
    end

    private def markdown_description(document : Markd::Node) : String?
      node = document.first_child?
      while node
        if node.type == Markd::Node::Type::Paragraph
          description = markdown_text(node)
          return description unless description.empty?
        end
        node = node.next?
      end
      nil
    end

    private def markdown_text(node : Markd::Node) : String
      String.build do |io|
        walker = node.walker
        while event = walker.next
          child, entering = event
          next unless entering
          case child.type
          when Markd::Node::Type::Text, Markd::Node::Type::Code
            io << child.text
          when Markd::Node::Type::SoftBreak, Markd::Node::Type::LineBreak
            io << ' '
          end
        end
      end.strip
    end

    private def markdown_code(value : String) : String
      raise Invalid.new("bootstrap substitution contains unsafe text") if value.includes?('`') || value.includes?('\n') || value.includes?('\r')
      "`#{value}`"
    end

    private def markdown_link_destination(value : String) : String
      if value.includes?('(') || value.includes?(')') ||
         value.includes?('\n') || value.includes?('\r')
        raise Invalid.new("bootstrap substitution contains unsafe text")
      end
      value
    end

    private def coordinate_block(coordinate : String?) : String
      return "" unless coordinate
      "\nThis line points to #{markdown_code(coordinate)}, who you will hopefully meet once you and your user have finished building the radio. If there is something in the fragment of this URL, that is their contact invitation code. You should be sure to remember that invitation code. Keep it private; the radio software will ask for it later, and these pages never receive or repeat it.\n"
    end

    private def meet_root(coordinate : String?, journey : String?) : String
      root = coordinate ? "/meet/#{URI.encode_path_segment(coordinate)}" : "/meet"
      journey ? "#{root}/#{journey}" : root
    end

    private def validate_journey!(journey : String?, action : String?) : Nil
      return if journey.nil? && action.nil?
      unless journey && JOURNEYS.includes?(journey)
        raise NotFound.new("meet journey does not exist")
      end
      unless action && self.class.action_allowed?(journey, action)
        raise NotFound.new("meet action does not exist")
      end
    end

    private def markdown_quote(value : String) : String
      value.lines(chomp: false).map do |line|
        line == "\n" ? ">\n" : "> #{line}"
      end.join
    end

    private def replace_once(source : String, marker : String,
                             value : String) : String
      first = source.index(marker) ||
              raise Invalid.new("bootstrap template is missing #{marker}")
      if source.index(marker, first + marker.bytesize)
        raise Invalid.new("bootstrap template repeats #{marker}")
      end
      source.sub(marker, value)
    end

    private def replace_all(source : String, marker : String,
                            value : String) : String
      raise Invalid.new("bootstrap template is missing #{marker}") unless source.includes?(marker)
      source.gsub(marker, value)
    end
  end
end
