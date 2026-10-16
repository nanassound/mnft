defmodule Mnft.Cad.Stl do
  @moduledoc """
  Deterministic pre-LLM analysis stage for one uploaded STL mesh.

  The engine sandbox bans mesh imports, so reversing a legacy STL has to
  happen before the LLM call: `attach/3` runs `cad_worker.stlprofile`
  (numpy stats, exact cross-section loops, orthographic renders), appends the
  analysis block to the prompt and hands the renders to the vision model as
  labeled images. The LLM then writes reconstruction code in the configured
  engine's dialect and the turn proceeds like any other.

  Nothing here ever raises: an analysis failure appends a visible note to the
  prompt (asking for a re-export) and the turn proceeds — same degradation as
  a missing poppler today.

  Config under `:mnft_cad, :cad, :stl` (all optional, defaults in
  `@defaults`); the profile run is replaceable via `:stl_profile_fun`
  (`{Mod, fun, args}`, called with the stl map) — that seam exists for tests.

  Decoded STL bytes live only in the turn process and one temp file deleted
  in `after`; persistence keeps metadata only.
  """

  require Logger

  alias Mnft.Cad.{Config, Events}

  @stl_url_re ~r/\Adata:(?:model\/stl|application\/sla);base64,([A-Za-z0-9+\/=]+)\z/

  @defaults [
    python_bin: "python3",
    max_stl_mb: 20,
    max_block_chars: 8000
  ]

  @profile_default {__MODULE__, :run_profile, []}

  @doc """
  Validate the (single) uploaded STL up front; never silently drop it.

  Accepts nil / empty map (no upload) or a map carrying a
  `data:model/stl;base64,…` or `data:application/sla;base64,…` URL within
  `max_stl_mb`. Returns `{:ok, %{data_url: url, name: name, size: bytes}}`
  or `{:error, reason}`.
  """
  @spec validate(term()) :: {:ok, %{data_url: String.t(), name: String.t(), size: pos_integer()}} | {:error, String.t()}
  def validate(nil), do: {:ok, nil}
  def validate(stl) when stl == %{}, do: {:ok, nil}

  def validate(stl) when is_map(stl) do
    url = data_url(stl) |> String.trim()
    max_mb = cfg()[:max_stl_mb] * 1.0

    with {:ok, b64} <- match_url(url),
         {:ok, raw} <- decode_b64(b64) do
      if byte_size(raw) > trunc(max_mb * 1_048_576) do
        {:error, "stl: #{mb(byte_size(raw))} MB attached, limit is #{mb(max_mb * 1_048_576)} MB"}
      else
        {:ok, %{data_url: url, name: name_of(stl), size: byte_size(raw)}}
      end
    end
  end

  def validate(_stl) do
    {:error, "stl: must be a map with a data:model/stl;base64 URL"}
  end

  defp match_url(url) do
    case Regex.run(@stl_url_re, url) do
      [_, b64] -> {:ok, b64}
      nil -> {:error, "stl: not a data:model/stl;base64 or data:application/sla;base64 URL"}
    end
  end

  defp decode_b64(b64) do
    case Base.decode64(b64) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, "stl: payload is not valid base64"}
    end
  end

  @doc """
  Run `cad_worker.stlprofile` over the upload: decode, temp file, one JSON
  profile back. Default `:stl_profile_fun` target; `{:error, reason}` on any
  failure (python missing, unparseable/truncated mesh), never raises.
  """
  @spec run_profile(term()) :: {:ok, map()} | {:error, String.t()}
  def run_profile(stl) when is_map(stl) do
    c = cfg()
    url = data_url(stl)
    b64 = url |> String.split(",", parts: 2) |> List.last()
    tmp = Path.join(System.tmp_dir!(), "mnft-stl-#{:rand.uniform(1_000_000)}.stl")

    with {:ok, raw} <- decode_b64(String.trim(b64)),
         {:ok, exe} <- resolve_python(c[:python_bin]) do
      File.write!(tmp, raw)

      try do
        case System.cmd(exe, ["-m", "cad_worker.stlprofile", tmp], stderr_to_stdout: true) do
          {out, code} -> parse_profile(out, code)
        end
      after
        File.rm(tmp)
      end
    end
  end

  defp resolve_python(bin) when is_binary(bin) do
    case find_python(bin) do
      nil -> {:error, "stl analyzer python not found: #{bin}"}
      exe -> {:ok, exe}
    end
  end

  defp resolve_python(_), do: {:error, "stl analyzer python_bin is not configured"}

  defp parse_profile(out, 0) do
    case Jason.decode(out) do
      {:ok, %{"ok" => true} = profile} -> {:ok, profile}
      _ -> {:error, "stl analyzer returned unusable output"}
    end
  end

  defp parse_profile(out, _code) do
    case Jason.decode(out) do
      {:ok, %{"error" => reason}} -> {:error, reason}
      _ -> {:error, "stl analyzer failed"}
    end
  end

  @doc """
  The STL stage for one turn. Returns `{llm_message, images, stl_meta}`:

    * `llm_message` — the message with the analysis block appended, or a
      failure note when the mesh could not be analyzed.
    * `images` — orthographic renders, same shape as
      `Mnft.Cad.Images.validate/1` entries with `label: "stl"`.
    * `stl_meta` — string-key-able metadata for journal persistence
      (`%{name, bytes, triangles, bbox_size, volume, components,
      watertight}`, or `%{name, bytes, error: reason}`), nil with no upload.

  Emits `stl_started` / `stl_done` events around the analysis. With no STL:
  `{message, [], nil}` and no events.
  """
  @spec attach(String.t(), String.t(), term()) :: {String.t(), [map()], map() | nil}
  def attach(_session_id, llm_message, nil), do: {llm_message, [], nil}
  def attach(_session_id, llm_message, stl) when stl == %{}, do: {llm_message, [], nil}

  def attach(session_id, llm_message, stl) when is_map(stl) do
    name = name_of(stl)
    Events.emit(session_id, "stl_started", %{name: name})

    case profile(stl) do
      {:ok, %{"stats" => stats} = profile} when is_map(stats) ->
        images = render_images(profile["renders"])
        block = format_block(name, Jason.encode!(profile))
        msg = llm_message <> "\n\n" <> block

        Events.emit(session_id, "stl_done", %{
          ok: true,
          triangles: stats["triangles"],
          components: stats["components"]
        })

        meta = %{
          name: name,
          bytes: size_of(stl),
          triangles: stats["triangles"],
          bbox_size: stats["bbox_size"],
          volume: stats["volume"],
          components: stats["components"],
          watertight: stats["watertight"]
        }

        {msg, images, meta}

      {:error, reason} ->
        Logger.warning("stl analysis failed: #{name} — #{reason}")
        msg = llm_message <> failure_note(reason)
        Events.emit(session_id, "stl_done", %{ok: false, reason: reason})
        {msg, [], %{name: name, bytes: size_of(stl), error: reason}}
    end
  end

  def attach(_session_id, llm_message, _stl), do: {llm_message, [], nil}

  defp profile(stl) do
    {mod, fun, args} = Config.get(:stl_profile_fun, @profile_default)
    apply(mod, fun, [stl | args])
  rescue
    e -> {:error, error_reason(e)}
  end

  defp failure_note(reason) do
    "\n\n[The attached STL could not be analyzed (#{reason}) — ask the user " <>
      "to re-export it as binary or ASCII STL]"
  end

  defp render_images(renders) when is_list(renders) do
    Enum.flat_map(renders, fn b64 ->
      case Base.decode64(b64) do
        {:ok, raw} ->
          [
            %{
              data_url: "data:image/png;base64," <> b64,
              media_type: "image/png",
              bytes: raw,
              size: byte_size(raw),
              label: "stl"
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp render_images(_), do: []

  @doc """
  Format the stlprofile JSON into the LLM analysis block. Pure: safe to test
  without a venv. Never returns "" — unparseable JSON yields the header +
  design-intent footer with no mesh/section lines (a failed parse is
  `attach/3`'s error path, not this function's).
  """
  @spec format_block(String.t(), String.t()) :: String.t()
  def format_block(stl_name, profile_json) when is_binary(profile_json) do
    header =
      "[Uploaded STL mesh \"#{stl_name}\" — reverse-engineer this part into " <>
        "parametric CAD.\nSTL files are unitless; all figures are raw STL " <>
        "units — treat them as millimetres unless the user says otherwise.\n"

    footer =
      "Reconstruct the DESIGN INTENT (holes, pockets, fillets, revolve " <>
        "profiles) as clean parametric code — mesh import is not available. " <>
        "Match the bounding box and volume within a few percent. State the " <>
        "dimensions you inferred.]"

    body =
      with {:ok, profile} <- Jason.decode(profile_json),
           stats when is_map(stats) <- profile["stats"] do
        sections = profile["sections"] || []
        cap = max(cfg()[:max_block_chars] - (String.length(header) + String.length(footer)), 0)

        mesh_line(stats) <> bbox_line(stats) <> section_lines(sections, cap)
      else
        _ -> ""
      end

    header <> body <> footer
  end

  defp mesh_line(stats) do
    bodies = if stats["components"] == 1, do: "1 body", else: "#{stats["components"]} bodies"

    "Mesh: #{commas(stats["triangles"])} triangles, #{bodies}, " <>
      "#{if stats["watertight"], do: "watertight", else: "not watertight"}, " <>
      "volume #{n2(stats["volume"])}, area #{n2(stats["area"])}.\n"
  end

  defp bbox_line(stats) do
    [x0, y0, z0] = stats["bbox_min"]
    [x1, y1, z1] = stats["bbox_max"]
    [w, d, h] = stats["bbox_size"]

    "Bounding box: x #{n2(x0)}..#{n2(x1)}, y #{n2(y0)}..#{n2(y1)}, " <>
      "z #{n2(z0)}..#{n2(z1)} (#{n2(w)} x #{n2(d)} x #{n2(h)}).\n"
  end

  defp section_lines(sections, cap) do
    intro =
      "Exact cross-section outlines — closed loops, mm, absolute part " <>
        "coordinates, section plane perpendicular to the axis at the given " <>
        "offset. Rebuild the 2D profiles from EXACTLY these vertices; do not " <>
        "add, drop, or straighten edges.\n"

    {lines_rev, _used, dropped} =
      Enum.reduce(sections, {[], String.length(intro), 0}, fn section, {acc, used, dropped} ->
        line = section_line(section)

        if used + String.length(line) > cap do
          {acc, used, dropped + 1}
        else
          {[line | acc], used + String.length(line), dropped}
        end
      end)

    note = if(dropped > 0, do: "[#{dropped} later sections omitted]\n", else: "")
    kept = Enum.reverse(lines_rev) |> Enum.join("")
    intro <> kept <> note
  end

  defp section_line(%{"axis" => axis, "offset" => offset, "loops" => loops})
       when is_list(loops) do
    loops
    |> Enum.map(fn loop ->
      pts = Enum.map_join(loop, " -> ", fn [x, y] -> "(#{n2(x)}, #{n2(y)})" end)
      "#{axis}=#{n2(offset)}: #{pts} [closes]\n"
    end)
    |> Enum.join("")
  end

  defp section_line(_section), do: ""

  # 2 dp, trailing zeros trimmed to at least one decimal; thousands-separated
  # when the integer part is large ("61204" -> "61,204").
  defp n2(x) when is_number(x) do
    r = Float.round(x * 1.0, 2)

    case :erlang.float_to_binary(r, [:compact, decimals: 2]) do
      s ->
        [int, dec] = String.split(s, ".")
        dec = if dec == "0", do: "0", else: String.replace_suffix(dec, "0", "") |> then(&if(&1 == "", do: "0", else: &1))
        commas(int) <> "." <> dec
    end
  end

  defp n2(other), do: to_string(other)

  defp commas(n) when is_integer(n), do: commas(Integer.to_string(n))

  defp commas("-" <> rest), do: "-" <> group(rest)
  defp commas(int) when is_binary(int), do: group(int)

  defp group(digits) do
    digits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.join(",")
  end

  defp data_url(stl) when is_map(stl), do: stl[:data_url] || stl["data_url"] || ""
  defp name_of(stl) when is_map(stl), do: stl[:name] || stl["name"] || "part.stl"

  defp size_of(stl) when is_map(stl), do: stl[:size] || stl["size"] || 0

  # Same resolution rule as References.find_python/1: bare names via PATH,
  # slash paths expanded against the cwd (config values may be relative).
  defp find_python(bin) when is_binary(bin) do
    if String.contains?(bin, "/") do
      bin |> Path.expand(File.cwd!()) |> System.find_executable()
    else
      System.find_executable(bin)
    end
  end

  defp error_reason(e) do
    case Exception.message(e) do
      "" -> "internal error"
      msg -> msg
    end
  end

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)

  defp cfg, do: Keyword.merge(@defaults, Config.get(:stl, []))
end
