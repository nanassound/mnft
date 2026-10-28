defmodule Mnft.Cad.ReferencesTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.{Config, References, TestEvents}

  # The :poppler-tagged cases run only where both poppler binaries exist
  # (CI installs them; dev machines without poppler still run the suite).
  poppler? =
    System.find_executable("pdftoppm") != nil and System.find_executable("pdftotext") != nil

  ExUnit.configure(exclude: [poppler: true], include: [poppler: poppler?])

  @pdf_bytes File.read!(Path.expand("../../fixtures/reference.pdf", __DIR__))
  @url "https://example.com/manuals/z-rails.pdf"

  setup do
    snapshot = Config.all()
    TestEvents.set(self())

    on_exit(fn ->
      TestEvents.unset()
      Application.put_env(:mnft_cad, :cad, snapshot)
    end)

    :ok
  end

  defp set_fetch(behavior) do
    cfg = Keyword.put(Config.all(), :references_fetch_fun, {__MODULE__, :fetch_stub, []})
    Application.put_env(:mnft_cad, :cad, cfg)
    Application.put_env(:mnft_cad, :test_fetch_behavior, behavior)
  end

  def fetch_stub(url) do
    case Application.get_env(:mnft_cad, :test_fetch_behavior) do
      :ok_pdf -> {:ok, @pdf_bytes}
      :skip -> :skip
      {:error, reason} -> {:error, reason}
      :raise -> raise "boom in fetch"
      %{} = routes -> Map.get(routes, url, {:error, "unexpected fetch URL #{inspect(url)}"})
    end
  end

  # --- detect/1 -----------------------------------------------------------------

  test "detect: no URLs" do
    assert References.detect("a 30 mm cube, please") == []
    assert References.detect(nil) == []
  end

  test "detect: one URL, in order, trailing punctuation excluded" do
    assert References.detect("Model rails #{@url}. Length 84HP") == [@url]
    assert References.detect("(#{@url}) is the sheet") == [@url]
    assert References.detect("see #{@url}, then decide") == [@url]
  end

  test "detect: multiple URLs keep order, deduplicated" do
    a = "https://a.example.com/x.pdf"
    b = "https://b.example.com/y.pdf"

    assert References.detect("compare #{a} with #{b}, also #{a}") == [a, b]
  end

  test "detect: capped at max_urls_per_turn (default 2)" do
    three = Enum.map_join(1..3, " ", &"https://x.example.com/p#{&1}.pdf")
    assert length(References.detect(three)) == 2
  end

  # --- fetch_pdf/1 --------------------------------------------------------------

  test "fetch_pdf: unreachable host becomes {:error, reason}, never raises" do
    assert {:error, reason} = References.fetch_pdf("http://127.0.0.1:9/z-rails.pdf")
    assert is_binary(reason) and reason != ""
  end

  # --- enrich/2 -----------------------------------------------------------------

  test "enrich: no URLs returns the message untouched, no events" do
    assert References.enrich("sess-1", "a 30 mm cube") == {"a 30 mm cube", [], []}
    refute_receive _
  end

  test "enrich: skipped (non-PDF) URLs leave the message and meta unchanged" do
    set_fetch(:skip)

    assert References.enrich("sess-1", "read #{@url} first") == {"read #{@url} first", [], []}
    assert_receive %{event: "fetch_started", payload: %{count: 1}}
    assert_receive %{event: "fetch_done", payload: %{fetched: 0, failed: []}}
  end

  test "enrich: fetch failure appends the failure note and reports it" do
    url = @url
    set_fetch({:error, "HTTP 500"})

    {msg, images, refs} = References.enrich("sess-1", "rails #{@url} 84HP")

    assert msg =~ "[Reference #{@url} could not be fetched (HTTP 500)"
    assert msg =~ "ask the user for the key dimensions"
    assert images == []
    assert refs == []

    assert_receive %{
      event: "fetch_done",
      payload: %{fetched: 0, failed: [%{url: ^url, reason: "HTTP 500"}]}
    }
  end

  # --- HTML datasheet portal shells ---------------------------------------------

  @shell_url "https://www.lcsc.com/datasheet/C5171427.pdf"

  @linked_pdf "https://datasheet.lcsc.com/datasheet/pdf/2c877f359f4f188d0b3546dbf275eeff.pdf?productCode=C5171427"

  @lcsc_shell """
  <html><head><link rel="canonical" href="#{@shell_url}"/></head><body>
  <script>window.location = '#{@linked_pdf}';</script>
  <a href="#{@linked_pdf}">Download datasheet</a>
  </body></html>
  """

  test "embedded_pdf_urls: extracts the real datasheet link from a portal shell" do
    assert References.embedded_pdf_urls(@lcsc_shell, @shell_url) == [@linked_pdf]
    assert References.embedded_pdf_urls("<html><body>login wall</body></html>") == []
  end

  @tag :poppler
  test "enrich: HTML shell at a .pdf URL follows the linked datasheet PDF" do
    set_fetch(%{@shell_url => {:ok, @lcsc_shell}, @linked_pdf => {:ok, @pdf_bytes}})

    {msg, images, refs} = References.enrich("sess-1", "model #{@shell_url}")

    pages = page_count()

    assert msg =~
             "[Reference datasheet #{@shell_url} — #{pages} page(s) attached as images]"

    assert length(images) == pages
    assert [%{"url" => @shell_url, "pages" => ^pages}] = refs
  end

  test "enrich: HTML shell without a PDF link degrades to the failure note" do
    set_fetch(%{@shell_url => {:ok, "<html><body>login required</body></html>"}})
    url = @shell_url

    {msg, images, refs} = References.enrich("sess-1", "model #{@shell_url}")

    assert msg =~
             "[Reference #{@shell_url} could not be fetched (got an HTML page, not a PDF)"

    assert msg =~ "ask the user for the key dimensions"
    assert images == []
    assert refs == []

    assert_receive %{
      event: "fetch_done",
      payload: %{fetched: 0, failed: [%{url: ^url, reason: "got an HTML page, not a PDF"}]}
    }
  end

  test "enrich: linked PDF that also returns HTML stays a fetch failure" do
    set_fetch(%{
      @shell_url => {:ok, @lcsc_shell},
      @linked_pdf => {:ok, "<html>still html</html>"}
    })

    {msg, images, refs} = References.enrich("sess-1", "model #{@shell_url}")

    assert msg =~
             "could not be fetched (linked PDF #{@linked_pdf} also returned non-PDF content)"

    assert images == []
    assert refs == []
  end

  test "enrich: a raising fetcher degrades to the failure note (never raises)" do
    url = @url
    set_fetch(:raise)

    {msg, images, refs} = References.enrich("sess-1", "rails #{@url}")

    assert msg =~ "[Reference #{@url} could not be fetched (boom in fetch)"
    assert images == []
    assert refs == []
    assert_receive %{event: "fetch_done", payload: %{failed: [%{url: ^url}]}}
  end

  test "enrich: at most max_urls_per_turn fetches per turn" do
    set_fetch(:ok_pdf)

    message = "compare #{Enum.map(1..3, &"https://x.example.com/p#{&1}.pdf") |> Enum.join(" ")}"

    {_msg, images, refs} = References.enrich("sess-1", message)

    assert length(refs) == 2
    assert length(images) == 2 * page_count()
  end

  @tag :poppler
  test "enrich: fetched PDF appends the reference block and returns page images" do
    set_fetch(:ok_pdf)

    {msg, images, refs} = References.enrich("sess-1", "rails #{@url} length 84HP")

    assert msg =~ "\n\n[Reference datasheet #{@url} — 1 page(s) attached as images]\n"
    assert msg =~ "427 mm"
    assert [%{data_url: "data:image/png;base64," <> _b64, media_type: "image/png"}] = images
    assert [%{"url" => @url, "pages" => 1, "text" => text}] = refs
    assert text =~ "427 mm"

    assert_receive %{event: "fetch_started", payload: %{count: 1}}
    assert_receive %{event: "fetch_done", payload: %{fetched: 1, pages: 1, failed: []}}
  end

  # --- pdf_to_parts/2 -----------------------------------------------------------

  @tag :poppler
  test "pdf_to_parts: renders PNG pages, extracts text, reports meta" do
    %{images: images, text: text, meta: meta} = References.pdf_to_parts(@url, @pdf_bytes)

    assert length(images) == 1
    assert [%{data_url: "data:image/png;base64," <> b64, media_type: "image/png", size: size}] =
             images

    assert Base.decode64!(String.slice(b64, 0, 8)) != ""
    assert size > 0 and size <= 4 * 1024 * 1024

    assert text =~ "427 mm"
    assert text =~ "84 HP"

    assert %{url: @url, pages: 1, text_chars: tc, tool: "poppler"} = meta
    assert tc > 0
  end

  # --- vector outline block -----------------------------------------------------

  @pdfprofile_json """
  {"loops": [{"page": 1, "closed": true,
              "points": [[0.0, 128.41], [2.8, 128.41], [305.36, 0.0]],
              "bbox": [305.36, 128.41],
              "callouts": ["23.8", "17.8", "6", "M4"]}]}
  """

  test "format_vector_block: renders header, callouts and vertices" do
    block = References.format_vector_block(@pdfprofile_json)

    assert block =~ "[Vector outline extracted"
    assert block =~ "calibrate"
    assert block =~ "dimension callouts near it: 23.8 17.8 6 M4"
    assert block =~ "closed, 3 pts, bbox 305.36 x 128.41 pt"
    assert block =~ "(0.00, 128.41) -> (2.80, 128.41) -> (305.36, 0.00) [closes]"
  end

  test "format_vector_block: empty loops or malformed json yield empty block" do
    assert References.format_vector_block(~s({"loops": []})) == ""
    assert References.format_vector_block("not json") == ""
    assert References.format_vector_block("") == ""
  end

  @tag :poppler
  test "pdf_to_parts: vector block degrades to empty string without ink" do
    cfg =
      Config.all()
      |> Keyword.put(:references,
        python_bin: Path.expand("../../../cad_worker/.venv/bin/python", __DIR__)
      )

    Application.put_env(:mnft_cad, :cad, cfg)

    %{vector: vector} = References.pdf_to_parts(@url, @pdf_bytes)
    assert is_binary(vector)
  end

  defp page_count do
    if System.find_executable("pdftoppm"), do: 1, else: 0
  end
end
