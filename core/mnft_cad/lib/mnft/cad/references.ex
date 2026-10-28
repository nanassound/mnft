defmodule Mnft.Cad.References do
  @moduledoc """
  Deterministic pre-LLM fetch stage for reference datasheets.

  A message like "Model this rails https://…/z-rails.pdf, length 84HP" used to
  reach the LLM as inert text: nothing fetched the URL, so the model had to
  guess the dimensions (and slow text models stalled on the datasheet-class
  reasoning). `enrich/2` runs before the LLM call: it detects URLs in the
  message, downloads PDFs, renders pages to PNG (poppler `pdftoppm`) and
  extracts text (`pdftotext`), then appends the text to the prompt and returns
  the rendered pages as images for the vision model.

  Scope: PDF references only (`application/pdf` content type or `.pdf` path).
  HTML and image URLs are left as plain text. Datasheet portals (LCSC et al.)
  serve an HTML viewer shell at the `.pdf` URL with the real file linked
  inside: that link is followed exactly once, and HTML that yields no PDF is
  a visible fetch failure — never a silent 0-page reference.

  Nothing here ever raises: every failure degrades to a note appended to the
  prompt asking the user for the key dimensions, and the turn proceeds.

  Config under `:mnft_cad, :cad, :references` (all optional, defaults shown in
  `@defaults`); the fetch call itself is replaceable via
  `:references_fetch_fun` (`{Mod, fun, args}`, called with the URL) — that
  seam exists for tests.
  """

  require Logger

  alias Mnft.Cad.Config
  alias Mnft.Cad.Events

  @url_re ~r{https?://[^\s<>"')\]]+}i

  @defaults [
    pdftoppm_bin: "pdftoppm",
    pdftotext_bin: "pdftotext",
    fetch_timeout_s: 30,
    max_pdf_mb: 20,
    max_pages: 3,
    pdf_dpi: 300,
    python_bin: "python3",
    max_text_chars: 4000,
    max_urls_per_turn: 2
  ]

  # Same limits as Mnft.Cad.Images for a single turn's images.
  @max_image_bytes 4 * 1024 * 1024
  @max_total_image_bytes 8 * 1024 * 1024

  @fetch_default {__MODULE__, :fetch_pdf, []}

  @doc """
  Ordered, unique URLs in the message, capped at `max_urls_per_turn`.
  Trailing sentence punctuation is not part of the URL.
  """
  @spec detect(term()) :: [String.t()]
  def detect(message) when is_binary(message) do
    @url_re
    |> Regex.scan(message, capture: :first)
    |> List.flatten()
    |> Enum.map(&Regex.replace(~r/[.,;:!?]+\z/, &1, ""))
    |> Enum.uniq()
    |> Enum.take(cfg()[:max_urls_per_turn])
  end

  def detect(_), do: []

  @doc """
  Download a PDF reference. Returns `{:ok, bytes}`, `:skip` (not a PDF: the
  final content type is not `application/pdf` and the URL path does not end
  in `.pdf`), or `{:error, reason}`.
  """
  @spec fetch_pdf(String.t()) :: {:ok, binary()} | {:error, String.t()} | :skip
  def fetch_pdf(url) when is_binary(url) do
    c = cfg()
    timeout_ms = c[:fetch_timeout_s] * 1000
    max_mb = c[:max_pdf_mb] * 1.0
    max_bytes = trunc(max_mb * 1_048_576)

    try do
      case Req.get(url, redirect: :follow, receive_timeout: timeout_ms) do
        {:ok, %Req.Response{status: 200, headers: headers, body: body}} ->
          cond do
            over_content_length?(headers, max_bytes) -> {:error, too_large(max_mb)}
            byte_size(body) > max_bytes -> {:error, too_large(max_mb)}
            pdf?(headers, url) -> {:ok, body}
            true -> :skip
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, exception} ->
          {:error, error_reason(exception)}
      end
    rescue
      e -> {:error, error_reason(e)}
    end
  end

  @doc """
  Render fetched PDF bytes into LLM image parts + extracted text.

  Writes the bytes to a temp file (always removed), runs `pdftoppm -png` for
  at most `max_pages` pages at `pdf_dpi` DPI, trims each page to its content
  bbox (`cad_worker.pngtrim`), extracts text (`pdftotext -layout`) and vector
  section outlines (`cad_worker.pdfprofile`). Image caps match
  `Mnft.Cad.Images` (4 MiB per page, 8 MiB per turn); pages beyond a cap are
  dropped.

  Returns `%{images: [image()], text: String.t(), vector: String.t(),
  meta: map()}` where `meta` reports `url`, rendered `pages`, `text_chars`,
  and the `tool` actually used (`"poppler"`, `"pdftotext"` when only text
  extraction is available, or `"none"` when both poppler binaries are
  missing). `vector` is the formatted vector-outline block for the LLM (or
  ""). Trim/outline failures degrade with a log warning, never an error.
  """
  @spec pdf_to_parts(String.t(), binary()) :: %{
          images: [map()],
          text: String.t(),
          vector: String.t(),
          meta: map()
        }
  def pdf_to_parts(url, bytes) when is_binary(bytes) do
    c = cfg()
    tmp = Path.join(System.tmp_dir!(), "mnft-ref-#{:rand.uniform(1_000_000)}.pdf")
    File.write!(tmp, bytes)

    try do
      pages = render_pages(tmp, c)
      text = extract_text(tmp, c)
      vector = extract_profile(tmp, c)

      tool =
        cond do
          pages != [] -> "poppler"
          System.find_executable(c[:pdftotext_bin]) != nil -> "pdftotext"
          true -> "none"
        end

      %{
        images: pages,
        text: text,
        vector: vector,
        meta: %{url: url, pages: length(pages), text_chars: String.length(text), tool: tool}
      }
    after
      File.rm!(tmp)
    end
  end

  @doc """
  The fetch stage for one turn. Returns
  `{llm_message, images, references_meta}`:

    * `llm_message` — the original message with a reference block appended
      per fetched PDF (page count + extracted text), or a failure note when a
      URL could not be fetched. Non-PDF URLs change nothing.
    * `images` — rendered datasheet pages (same shape as
      `Mnft.Cad.Images.validate/1` entries, no `:thumb`).
    * `references_meta` — `%{"url" =>, "pages" =>, "text" =>}` per fetched
      reference, string-keyed for journal persistence.

  Emits `fetch_started` / `fetch_done` events around the fetches. With no
  URLs detected: `{message, [], []}` and no events.
  """
  @spec enrich(String.t(), String.t()) :: {String.t(), [map()], [map()]}
  def enrich(session_id, message) when is_binary(message) do
    case detect(message) do
      [] ->
        {message, [], []}

      urls ->
        Events.emit(session_id, "fetch_started", %{count: length(urls)})

        {llm_message, images, refs, failed} =
          Enum.reduce(urls, {message, [], [], []}, &handle_url/2)

        Events.emit(session_id, "fetch_done", %{
          fetched: length(refs),
          pages: refs |> Enum.map(& &1["pages"]) |> Enum.sum(),
          failed: failed
        })

        {llm_message, images, refs}
    end
  end

  defp handle_url(url, {msg, images, refs, failed}) do
    case fetch_one(url) do
      {:ok, %{images: page_images, text: text, vector: vector, pages: pages}} ->
        if pages == 0 and String.trim(text) == "" and String.trim(vector) == "" do
          reason = "fetched but no readable pages or text (portal shell or unsupported PDF)"

          Logger.warning("reference fetch empty: #{url} — #{reason}")
          {msg <> failure_note(url, reason), images, refs,
           failed ++ [%{url: url, reason: reason}]}
        else
          note =
            "\n\n[Reference datasheet #{url} — #{pages} page(s) attached as images]\n" <>
              text <> vector

          {msg <> note, images ++ page_images,
           refs ++ [%{"url" => url, "pages" => pages, "text" => text}], failed}
        end

      :skip ->
        {msg, images, refs, failed}

      {:error, reason} ->
        Logger.warning("reference fetch failed: #{url} — #{reason}")
        {msg <> failure_note(url, reason), images, refs, failed ++ [%{url: url, reason: reason}]}
    end
  end

  defp failure_note(url, reason) do
    "\n\n[Reference #{url} could not be fetched (#{reason}) — " <>
      "ask the user for the key dimensions]"
  end

  # One URL: fetch + parse. Any internal error becomes a fetch failure, never
  # a crash — the turn must proceed.
  defp fetch_one(url) do
    try do
      {mod, fun, args} = Config.get(:references_fetch_fun, @fetch_default)
      fetch = fn u -> apply(mod, fun, [u | args]) end

      with {:ok, bytes} <- fetch.(url),
           pdf_bytes when is_binary(pdf_bytes) <- ensure_pdf_bytes(url, bytes, fetch),
           %{images: images, text: text, vector: vector, meta: %{pages: pages}} <-
             pdf_to_parts(url, pdf_bytes) do
        {:ok, %{images: images, text: text, vector: vector, pages: pages}}
      end
    rescue
      e -> {:error, error_reason(e)}
    end
  end

  defp over_content_length?(headers, max_bytes) do
    case headers |> Map.get("content-length", []) |> List.first() do
      nil -> false
      len ->
        case Integer.parse(to_string(len)) do
          {n, _} -> n > max_bytes
          _ -> false
        end
    end
  end

  # A fetched "PDF" must actually be PDF bytes. An HTML shell at a .pdf URL is
  # a fetch failure (never a silent 0-page reference) unless the page links
  # the real file — then follow it exactly once.
  defp ensure_pdf_bytes(url, bytes, fetch) do
    if pdf_bytes?(bytes) do
      bytes
    else
      follow_linked_pdf(url, bytes, fetch)
    end
  end

  defp follow_linked_pdf(url, bytes, fetch) do
    case embedded_pdf_urls(bytes, url) do
      [] ->
        {:error, "got an HTML page, not a PDF"}

      [link | _] ->
        Logger.warning("reference #{url} is an HTML shell; following linked PDF #{link}")

        case fetch.(link) do
          {:ok, pdf} ->
            if pdf_bytes?(pdf) do
              pdf
            else
              {:error, "linked PDF #{link} also returned non-PDF content"}
            end

          :skip ->
            {:error, "linked PDF #{link} unavailable"}

          {:error, reason} ->
            {:error, "linked PDF #{link}: #{reason}"}
        end
    end
  end

  # %PDF magic within the leading 1 KiB (some producers prepend junk).
  defp pdf_bytes?(bytes) when is_binary(bytes) do
    String.contains?(binary_part(bytes, 0, min(byte_size(bytes), 1024)), "%PDF")
  end

  defp pdf_bytes?(_), do: false

  @linked_pdf_re ~r{https?://[^\s<>"')\]]+\.pdf(?:\?[^\s<>"')\]]*)?}i

  @doc """
  Absolute PDF URLs embedded in an HTML page, minus `exclude` (the URL we
  already tried), deduplicated, in order. Pure: safe to test without a venv.
  """
  @spec embedded_pdf_urls(String.t(), String.t() | nil) :: [String.t()]
  def embedded_pdf_urls(html, exclude \\ nil) when is_binary(html) do
    @linked_pdf_re
    |> Regex.scan(html, capture: :first)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, "&amp;", "&"))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == exclude))
  end

  defp too_large(max_mb), do: "pdf larger than #{mb(max_mb)} MB"

  defp pdf?(headers, url) do
    mime =
      headers |> Map.get("content-type", []) |> List.first("") |> String.downcase() |> String.trim()

    String.starts_with?(mime, "application/pdf") or path_pdf?(url)
  end

  defp path_pdf?(url) do
    case URI.parse(url).path do
      path when is_binary(path) -> String.ends_with?(String.downcase(path), ".pdf")
      _ -> false
    end
  end

  defp render_pages(tmp, c) do
    bin = System.find_executable(c[:pdftoppm_bin])
    prefix = tmp <> "-page"

    with bin when is_binary(bin) <- bin,
         {_, 0} <-
           System.cmd(
             bin,
             ["-png", "-r", to_string(c[:pdf_dpi]), "-l", to_string(c[:max_pages]), tmp, prefix],
             stderr_to_stdout: true
           ) do
      paths =
        prefix
        |> then(&Path.wildcard(&1 <> "*.png"))
        |> Enum.sort_by(&page_number/1)

      # Trim each page to its content bbox (cad_worker.pngtrim) so the vision
      # model sees the drawing, not the A4 margin. Any failure keeps the
      # untrimmed page — a broken trim must never drop a datasheet page.
      read_paths = Enum.map(paths, &trim_page(&1, c))

      pages = read_paths |> Enum.map(&read_page/1) |> cap_images()
      Enum.each(read_paths, &File.rm/1)
      pages
    else
      nil ->
        []

      {output, code} ->
        Logger.warning("pdftoppm failed (exit #{code}): #{String.slice(output, 0, 300)}")
        []
    end
  end

  # Trim one rendered page to its content bbox via `python -m
  # cad_worker.pngtrim` (Pillow, in the cad_worker venv). Returns the path to
  # read — the trimmed file on success, the original page otherwise.
  defp trim_page(path, c) do
    trimmed = path <> "-trimmed.png"

    case find_python(c[:python_bin]) do
      nil ->
        Logger.warning("pngtrim skipped: python_bin #{c[:python_bin]} not found")
        path

      exe ->
        case System.cmd(exe, ["-m", "cad_worker.pngtrim", path, trimmed],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            if File.exists?(trimmed) do
              File.rm(path)
              trimmed
            else
              Logger.warning("pngtrim produced no output for #{Path.basename(path)}")
              path
            end

          {output, code} ->
            Logger.warning("pngtrim failed (exit #{code}): #{String.slice(output, 0, 300)}")
            path
        end
    end
  end

  # Bare names ("python3") resolve via PATH. Slash paths are cwd-relative
  # config values (like :worker_python) — find_executable/1 ignores relative
  # paths containing a slash, so expand them against the cwd first.
  defp find_python(bin) when is_binary(bin) do
    if String.contains?(bin, "/") do
      bin |> Path.expand(File.cwd!()) |> System.find_executable()
    else
      System.find_executable(bin)
    end
  end

  defp find_python(_), do: nil

  @doc """
  Format `cad_worker.pdfprofile` JSON into the LLM vector-outline block, ""
  when the JSON is empty or malformed. Pure: safe to test without a venv.
  """
  @spec format_vector_block(String.t()) :: String.t()
  def format_vector_block(json) when is_binary(json) do
    with {:ok, %{"loops" => loops}} when is_list(loops) and loops != [] <- Jason.decode(json) do
      header =
        "[Vector outline extracted from the datasheet drawing ink — exact page " <>
          "coordinates, y up, origin at each outline's min corner. The sheet " <>
          "draws each view at its own scale — calibrate with ONE factor: pair " <>
          "the outline's LONGEST bbox side with the LARGEST dimension callout " <>
          "listed for it (the overall dimension is the biggest number, never a " <>
          "sum of segment callouts) and scale both axes by it. Build the 2D " <>
          "cross-section from EXACTLY these vertices in order — do not add, " <>
          "drop, or straighten edges.]"

      body =
        Enum.map_join(loops, "\n", fn loop ->
          pts = loop["points"] || []
          [w, h] = loop["bbox"] || [0.0, 0.0]
          callouts = Enum.join(loop["callouts"] || [], " ")

          coords =
            pts
            |> Enum.map(fn [x, y] -> "(#{f2(x)}, #{f2(y)})" end)
            |> Enum.join(" -> ")

          "Outline (closed, #{length(pts)} pts, bbox #{f2(w)} x #{f2(h)} pt; " <>
            "dimension callouts near it: #{callouts})\n#{coords} [closes]"
        end)

      header <> "\n" <> String.slice(body, 0, 8000)
    else
      _ -> ""
    end
  end

  defp f2(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)

  # Run cad_worker.pdfprofile over the fetched PDF and format the block.
  # Any failure (venv python missing, pymupdf missing, no closed ink) yields ""
  # — the turn proceeds on images + text alone.
  defp extract_profile(tmp, c) do
    case find_python(c[:python_bin]) do
      nil ->
        ""

      exe ->
        case System.cmd(exe, ["-m", "cad_worker.pdfprofile", tmp, to_string(c[:max_pages])],
               stderr_to_stdout: true
             ) do
          {out, 0} ->
            format_vector_block(out)

          {output, code} ->
            Logger.warning("pdfprofile failed (exit #{code}): #{String.slice(output, 0, 300)}")

            ""
        end
    end
  end

  defp read_page(path) do
    case File.read(path) do
      {:ok, raw} ->
        %{
          data_url: "data:image/png;base64," <> Base.encode64(raw),
          media_type: "image/png",
          bytes: raw,
          size: byte_size(raw),
          label: "reference"
        }

      _ ->
        nil
    end
  end

  # Sequential caps: the first page over a cap drops the rest.
  defp cap_images(pages) do
    {kept, _, _} =
      Enum.reduce(pages, {[], 0, false}, fn page, {acc, total, full} ->
        cond do
          full -> {acc, total, true}
          page.size > @max_image_bytes -> {acc, total, true}
          total + page.size > @max_total_image_bytes -> {acc, total, true}
          true -> {[page | acc], total + page.size, false}
        end
      end)

    Enum.reverse(kept)
  end

  defp page_number(path) do
    case Regex.run(~r/(\d+)\.png\z/, path) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp extract_text(tmp, c) do
    case System.find_executable(c[:pdftotext_bin]) do
      nil ->
        ""

      bin ->
        case System.cmd(bin, ["-layout", tmp, "-"], stderr_to_stdout: true) do
          {text, 0} -> text |> String.trim() |> String.slice(0, c[:max_text_chars])
          {output, code} ->
            Logger.warning("pdftotext failed (exit #{code}): #{String.slice(output, 0, 300)}")
            ""
        end
    end
  end

  defp error_reason(e) do
    case Exception.message(e) do
      "" -> "internal error"
      msg -> msg
    end
  end

  defp mb(mega_bytes), do: :erlang.float_to_binary(mega_bytes / 1.0, decimals: 1)

  defp cfg, do: Keyword.merge(@defaults, Config.get(:references, []))
end
