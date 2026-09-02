require "./spec_helper"

describe "the canonical bootstrap representations" do
  it "serves one canonical public homepage as Markdown and HTML" do
    TinrelaySpec.with_server do |_root, _token, origin, api|
      expected = api.bootstrap_page.static("home.md")
      markdown = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      markdown.status_code.should eq(200)
      markdown.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      markdown.headers["Vary"].should eq("Accept")
      markdown.body.should eq(expected)

      explicit = HTTP::Client.get("#{origin}/index.md")
      explicit.status_code.should eq(200)
      explicit.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      explicit.body.should eq(expected)

      browser = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      browser.body.should eq(
        api.bootstrap_page.html(expected, false, "/index.md", "home")
      )
      browser.body.should contain(%(data-page="home"))
      browser.body.should contain(%(<link rel="canonical" href="https://tinrelay.space/">))
      browser.body.should contain(%(<link rel="alternate" type="text/markdown" href="/index.md">))
      browser.headers["Link"].should contain("/index.md")
      browser.headers["X-Robots-Tag"]?.should be_nil

      with_fragment = HTTP::Client.get("#{origin}/#private-fragment")
      with_fragment.body.should eq(browser.body)
      with_fragment.body.should_not contain("private-fragment")

      head = HTTP::Client.head(
        origin, headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      head.status_code.should eq(200)
      head.body.should be_empty
      head.headers["Content-Length"].to_i.should eq(expected.bytesize)

      browser_head = HTTP::Client.head(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      browser_head.status_code.should eq(200)
      browser_head.body.should be_empty
      browser_head.headers["Content-Type"].should eq("text/html; charset=utf-8")
      browser_head.headers["Content-Length"].to_i.should eq(browser.body.bytesize)
    end
  end

  it "serves exact canonical Markdown and renders only those bytes for browsers" do
    TinrelaySpec.with_server do |_root, _token, origin, api|
      expected = api.bootstrap_page.markdown
      markdown = HTTP::Client.get(
        "#{origin}/meet", headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      markdown.status_code.should eq(200)
      markdown.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      markdown.headers["Vary"].should eq("Accept")
      markdown.headers["Referrer-Policy"].should eq("no-referrer")
      markdown.body.should eq(expected)

      explicit = HTTP::Client.get("#{origin}/meet/index.md")
      explicit.body.should eq(expected)
      explicit.headers["Content-Type"].should eq("text/markdown; charset=utf-8")

      browser = HTTP::Client.get(
        "#{origin}/meet", headers: HTTP::Headers{"Accept" => "text/html"}
      )
      browser.body.should eq(
        api.bootstrap_page.html(expected, false, "/meet/index.md", "meet")
      )
      browser.headers["Content-Security-Policy"].should contain("default-src 'none'")
      browser.headers["Content-Security-Policy"].should contain("style-src 'self'")
      browser.headers["Content-Security-Policy"].should_not contain("'unsafe-inline'")
      browser.headers["Content-Security-Policy"].should contain("img-src 'self'")
      browser.headers["Content-Security-Policy"].should contain("font-src 'self'")
      browser.headers["Link"].should contain("/meet/index.md")

      refused_markdown = HTTP::Client.get(
        "#{origin}/meet",
        headers: HTTP::Headers{"Accept" => "text/markdown;q=0.0, text/html;q=1"}
      )
      refused_markdown.headers["Content-Type"].should eq("text/html; charset=utf-8")
      refused_markdown.body.should eq(browser.body)

      head = HTTP::Client.head(
        "#{origin}/meet", headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      head.status_code.should eq(200)
      head.body.should be_empty
      head.headers["Content-Length"].to_i.should eq(expected.bytesize)
    end
  end

  it "serves the plain built-in presentation without external art" do
    TinrelaySpec.with_server do |_root, _token, origin, _api|
      stylesheet = HTTP::Client.get("#{origin}/assets/tinrelay/plain.css")
      stylesheet.status_code.should eq(200)
      stylesheet.headers["Content-Type"].should eq("text/css; charset=utf-8")
      stylesheet.headers["X-Content-Type-Options"].should eq("nosniff")
      stylesheet.body.should_not be_empty

      HTTP::Client.get(
        "#{origin}/assets/tinrelay/not-allowlisted.css"
      ).status_code.should eq(404)
      HTTP::Client.get(
        "#{origin}/assets/tinrelay/../common-bootstrap.md"
      ).status_code.should eq(404)
    end
  end

  it "keeps directed coordinates out of generic metadata and never receives fragments" do
    TinrelaySpec.with_server do |_root, _token, origin, api|
      coordinate = "steward@harbor"
      expected = api.bootstrap_page.markdown(coordinate)
      response = HTTP::Client.get(
        "#{origin}/meet/steward%40harbor#must-not-reach-server",
        headers: HTTP::Headers{"Accept" => "text/html"}
      )
      response.status_code.should eq(200)
      response.headers["Cache-Control"].should eq("no-store")
      response.headers["X-Robots-Tag"].should contain("noindex")
      response.body.should eq(
        api.bootstrap_page.html(
          expected, true, "/meet/index.md/steward%40harbor", "meet"
        )
      )
      response.body.should contain(coordinate)
      response.body.should_not contain("must-not-reach-server")
      response.body.split("</head>", 2).first.should_not contain(coordinate)

      markdown = HTTP::Client.get("#{origin}/meet/index.md/steward%40harbor")
      markdown.body.should eq(expected)
      markdown.headers["X-Robots-Tag"].should contain("noindex")
    end
  end

  it "serves the JS-less mentorless and directed meet adventure from canonical Markdown" do
    TinrelaySpec.with_server do |_root, _token, origin, api|
      journeys = {
        "already-aboard" => %w(already-aboard open-the-schematics make-it-run name-the-ship keep-the-keys tune-the-radio hear-the-ping return-to-silence open-the-channel the-line-stays-open),
        "first-light"    => %w(first-light talk-together find-a-place open-the-schematics make-it-run take-a-pulse name-the-ship keep-the-keys tune-the-radio hear-the-ping return-to-silence open-the-channel the-line-stays-open),
      }

      mentorless_entry = HTTP::Client.get(
        "#{origin}/meet", headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      mentorless_entry.body.should contain("/meet/already-aboard")
      mentorless_entry.body.should contain("/meet/first-light")
      mentorless_entry.headers["Set-Cookie"]?.should be_nil

      journeys.each do |journey, actions|
        actions.each do |action|
          suffix = action == journey ? journey : "#{journey}/#{action}"
          markdown = HTTP::Client.get(
            "#{origin}/meet/#{suffix}",
            headers: HTTP::Headers{"Accept" => "text/markdown"}
          )
          markdown.status_code.should eq(200)
          markdown.body.should_not match(/\{\{[A-Z_]+\}\}/)
          markdown.headers["X-Robots-Tag"].should contain("noindex")
        end
      end

      [nil, "steward@harbor"].each do |coordinate|
        base = coordinate ? "/meet/steward%40harbor" : "/meet"
        journeys.each_key do |journey|
          [
            {"tune-the-radio", "hear-the-ping"},
            {"hear-the-ping", "return-to-silence"},
            {"return-to-silence", "open-the-channel"},
          ].each do |action, next_action|
            rendered = api.bootstrap_page.markdown(coordinate, action, journey)
            rendered.should contain("](#{base}/#{journey}/#{next_action})")
          end
        end
      end

      coordinate = "steward@harbor"
      encoded = "steward%40harbor"
      directed_entry = HTTP::Client.get(
        "#{origin}/meet/#{encoded}",
        headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      coordinate_at = directed_entry.body.index("`#{coordinate}`").not_nil!
      action_at = directed_entry.body.index("/meet/#{encoded}/already-aboard").not_nil!
      coordinate_at.should be < action_at
      directed_entry.headers["Set-Cookie"]?.should be_nil
      directed_entry.body.scan(/\]\(([^)]+)\)/).each do |match|
        target = match[1]
        target.should_not contain('#')
        target.should_not contain('?')
      end

      journeys.each do |journey, actions|
        actions.each do |action|
          suffix = action == journey ? journey : "#{journey}/#{action}"
          path = "/meet/#{encoded}/#{suffix}"
          markdown = HTTP::Client.get(
            "#{origin}#{path}#private-fragment",
            headers: HTTP::Headers{"Accept" => "text/markdown"}
          )
          markdown.status_code.should eq(200)
          markdown.body.should_not match(/\{\{[A-Z_]+\}\}/)
          markdown.body.should_not contain("private-fragment")
          markdown.headers["X-Robots-Tag"].should contain("noindex")
        end
      end

      {
        "already-aboard" => "open-the-schematics",
        "first-light"    => "open-the-channel",
      }.each do |journey, action|
        suffix = "#{journey}/#{action}"
        path = "/meet/#{encoded}/#{suffix}"
        markdown = HTTP::Client.get(
          "#{origin}#{path}",
          headers: HTTP::Headers{"Accept" => "text/markdown"}
        )
        expected = api.bootstrap_page.markdown(coordinate, action, journey)
        markdown.body.should eq(expected)
        explicit_path = "/meet/index.md/#{encoded}/#{suffix}"
        HTTP::Client.get("#{origin}#{explicit_path}").body.should eq(expected)
        browser = HTTP::Client.get(
          "#{origin}#{path}", headers: HTTP::Headers{"Accept" => "text/html"}
        )
        browser.body.should eq(
          api.bootstrap_page.html(expected, true, explicit_path, action)
        )
      end

      head = HTTP::Client.head("#{origin}/meet/#{encoded}/first-light/open-the-schematics")
      head.status_code.should eq(200)
      head.body.should be_empty
      HTTP::Client.get("#{origin}/meet/#{encoded}/first-light/unknown").status_code.should eq(404)
      HTTP::Client.get("#{origin}/meet/open-the-schematics").status_code.should eq(404)
    end
  end

  it "keeps raw template HTML inert" do
    root = TinrelaySpec.temporary_root
    begin
      File.write(
        File.join(root, "common-bootstrap.md"),
        "# Safe\n\n{{COORDINATE_BLOCK}}\n<script>window.bad = true</script>\n\n[Continue]({{MEET_ROOT}})\n"
      )
      File.write(File.join(root, "meet-shell.html"), "<html><body>{{BODY}}</body></html>\n")
      page = Tinrelay::BootstrapPage.new(
        File.join(root, "common-bootstrap.md"),
        "https://example.test/tinrelay.git"
      )
      rendered = page.html(page.markdown, false, "/meet/index.md", "meet")
      rendered.should_not contain("<script>")
      rendered.should contain("<!-- raw HTML omitted -->")
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "uses the first Markdown title in the HTML document title" do
    root = TinrelaySpec.temporary_root
    begin
      File.write(File.join(root, "common-bootstrap.md"), "# Placeholder\n")
      File.write(
        File.join(root, "meet-shell.html"),
        "<html><head><title>{{TITLE}}</title></head><body>{{BODY}}</body></html>\n"
      )
      page = Tinrelay::BootstrapPage.new(
        File.join(root, "common-bootstrap.md"),
        "https://example.test/tinrelay.git"
      )

      rendered = page.html(
        "# A *small* &amp; safe title\n\nBody.\n",
        false,
        "/meet/index.md",
        "meet"
      )
      rendered.should contain("<title>A small &amp; safe title - Tinrelay</title>")
      rendered.should contain("<h1>A <em>small</em> &amp; safe title</h1>")

      untitled = page.html("Body only.\n", false, "/meet/index.md", "meet")
      untitled.should contain("<title>Tinrelay</title>")
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "selects optional runtime art by stable page key without changing Markdown" do
    root = TinrelaySpec.temporary_root
    begin
      manifest = File.join(root, "art.json")
      File.write(
        manifest,
        {
          "home"             => "/tinrelay-art/home.71ae.css",
          "meet"             => "/tinrelay-art/meet.a81c.css",
          "open-the-channel" => "/tinrelay-art/open-the-channel.918e.css",
        }.to_json
      )
      TinrelaySpec.with_server(manifest) do |_server_root, _token, origin, api|
        home = HTTP::Client.get(
          origin, headers: HTTP::Headers{"Accept" => "text/html"}
        )
        home.body.should contain(%(data-page="home"))
        home.body.should contain(%(href="/tinrelay-art/home.71ae.css"))

        entry = HTTP::Client.get(
          "#{origin}/meet", headers: HTTP::Headers{"Accept" => "text/html"}
        )
        entry.body.should contain(%(href="/assets/tinrelay/plain.css"))
        entry.body.should contain(%(href="/tinrelay-art/meet.a81c.css"))

        action = HTTP::Client.get(
          "#{origin}/meet/steward%40harbor/first-light/open-the-channel",
          headers: HTTP::Headers{"Accept" => "text/html"}
        )
        action.body.should contain(%(href="/tinrelay-art/open-the-channel.918e.css"))
        action.body.should_not contain("steward@harbor.css")

        unstyled = HTTP::Client.get(
          "#{origin}/meet/first-light",
          headers: HTTP::Headers{"Accept" => "text/html"}
        )
        unstyled.body.should contain(%(href="/assets/tinrelay/plain.css"))
        unstyled.body.should_not contain("/tinrelay-art/")

        markdown = HTTP::Client.get(
          "#{origin}/meet",
          headers: HTTP::Headers{"Accept" => "text/markdown"}
        )
        markdown.body.should eq(api.bootstrap_page.markdown)
        markdown.body.should_not contain("/tinrelay-art/")
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "rejects malformed runtime art configuration before serving" do
    root = TinrelaySpec.temporary_root
    begin
      oversized_pipe = File.join(root, "oversized.pipe")
      Process.run("mkfifo", [oversized_pipe]).success?.should be_true
      writer = Process.new(
        "dd",
        ["if=/dev/zero", "of=#{oversized_pipe}",
         "bs=#{Tinrelay::ArtManifest::MAX_BYTES + 1}", "count=1"],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      oversized = expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(
          oversized_pipe, Tinrelay::BootstrapPage::PAGE_KEYS
        )
      end
      oversized.message.should eq(
        "art manifest exceeds #{Tinrelay::ArtManifest::MAX_BYTES} bytes"
      )
      writer.wait.success?.should be_true

      invalid_json = File.join(root, "invalid.json")
      File.write(invalid_json, "[]")
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(invalid_json, Tinrelay::BootstrapPage::PAGE_KEYS)
      end

      unknown_page = File.join(root, "unknown-page.json")
      File.write(unknown_page, {"future-page" => "/art/future.css"}.to_json)
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(unknown_page, Tinrelay::BootstrapPage::PAGE_KEYS)
      end

      unsafe_url = File.join(root, "unsafe-url.json")
      File.write(unsafe_url, {"meet" => "https://outside.example/meet.css"}.to_json)
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(unsafe_url, Tinrelay::BootstrapPage::PAGE_KEYS)
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "keeps public discovery bounded and negotiates unknown routes" do
    TinrelaySpec.with_server do |_root, _token, origin, _api|
      trailing = HTTP::Client.get("#{origin}/meet/")
      trailing.status_code.should eq(308)
      trailing.headers["Location"].should eq("/meet")
      HTTP::Client.get("#{origin}/join").status_code.should eq(404)
      HTTP::Client.get(origin).status_code.should eq(200)

      llms = HTTP::Client.get("#{origin}/llms.txt")
      llms.status_code.should eq(200)
      llms.body.should contain("/index.md")
      llms.body.should contain("/meet/index.md")
      robots = HTTP::Client.get("#{origin}/robots.txt")
      robots.body.should contain("Allow: /$")
      robots.body.should contain("Disallow: /v1/")
      sitemap = HTTP::Client.get("#{origin}/sitemap.xml")
      sitemap.body.should contain("<loc>https://tinrelay.space/</loc>")
      sitemap.body.should contain("https://tinrelay.space/meet")
      sitemap.body.should_not contain("steward@harbor")

      public_missing = HTTP::Client.get(
        "#{origin}/missing",
        headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      public_missing.status_code.should eq(404)
      public_missing.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      api_missing = HTTP::Client.get(
        "#{origin}/v1/missing",
        headers: HTTP::Headers{"X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s}
      )
      api_missing.status_code.should eq(404)
      api_missing.headers["Content-Type"].should start_with("application/json")
    end
  end
end
