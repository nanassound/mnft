defmodule Mnft.Cad.CodeGen do
  @moduledoc """
  Code-block extraction, truncation diagnosis, and repair-message builders.

  Ported from the PoC's `backend/llm.py` / `backend/runner.py`; the strings
  are part of the UI contract and the repair-prompt tuning -- keep them exact.
  """

  alias Mnft.Cad.Prompt

  # scad/openscad tags: the OpenSCAD dialect demands python-tagged fences,
  # but models sometimes emit the natural tag anyway — read it rather than
  # discard a complete script.
  @tagged_block_re ~r/```(?:python|py|scad|openscad)[ \t]*\r?\n(.*?)```/s
  @any_block_re ~r/```[ \t]*\r?\n(.*?)```/s
  @cam_block_re ~r/```cam[ \t]*\r?\n(.*?)```/s
  @data_url_re ~r/data:image\/[a-z0-9.+-]+;base64,[A-Za-z0-9+\/=]+/

  @doc """
  Return the last non-empty fenced python block in `text`, else nil.
  Tagged (python/py) blocks win; the bare-fence pattern is only consulted
  when no tagged block exists at all.
  """
  def extract_code(text) when is_binary(text) and text != "" do
    blocks =
      case matches(@tagged_block_re, text) do
        [] -> matches(@any_block_re, text)
        tagged -> tagged
      end

    Enum.reverse(blocks)
    |> Enum.find_value(fn block ->
      block = String.trim(block)
      if block != "", do: block
    end)
  end

  def extract_code(_), do: nil

  @doc """
  The last fenced `cam` block in `text`, decoded: `:none` when the reply has
  no `cam` block at all, `{:ok, plan}` when it holds a JSON object, else
  `{:error, msg}` (invalid JSON or non-object body).
  """
  def extract_cam_json(text) when is_binary(text) and text != "" do
    case Regex.scan(@cam_block_re, text) do
      [] ->
        :none

      blocks ->
        body = blocks |> List.last() |> Enum.at(1) |> String.trim()

        case Jason.decode(body) do
          {:ok, plan} when is_map(plan) -> {:ok, plan}
          {:ok, _} -> {:error, "the cam block must be a JSON object"}
          {:error, reason} -> {:error, "the cam block is not valid JSON: #{Exception.message(reason)}"}
        end
    end
  end

  def extract_cam_json(_), do: :none

  @doc """
  Replace every complete fenced code block with `[earlier code elided]`.
  Unterminated fences (truncated historical replies) are left untouched.
  """
  def strip_code_blocks(content) when is_binary(content) do
    Regex.replace(~r/```[^\n]*\n.*?```/s, content, "[earlier code elided]")
    |> String.trim()
  end

  @doc "Why `text` has no complete code block due to truncation, else nil."
  def truncation_reason(text, finish_reason) do
    reason = finish_reason |> to_string() |> String.trim() |> String.downcase()

    if reason == "length" do
      "finish_reason was 'length' (token limit)"
    else
      if is_binary(text) and rem(count_fences(text), 2) == 1 do
        "the reply ends inside an unterminated code fence"
      else
        nil
      end
    end
  end

  @doc "Best-effort recovery of the unfinished code from a truncated reply."
  def partial_code(text) when is_binary(text) and text != "" do
    if String.contains?(text, "```") do
      after_fence =
        case String.split(text, "```") |> List.last() do
          "" -> ""
          after_tag -> after_tag |> strip_lang_tag() |> String.trim()
        end

      if after_fence != "", do: after_fence
    end
  end

  def partial_code(_), do: nil

  defp strip_lang_tag("python" <> rest), do: drop_first_nl(rest)
  defp strip_lang_tag("py" <> rest), do: drop_first_nl(rest)
  defp strip_lang_tag("scad" <> rest), do: drop_first_nl(rest)
  defp strip_lang_tag("openscad" <> rest), do: drop_first_nl(rest)
  defp strip_lang_tag("\n" <> rest), do: rest
  defp strip_lang_tag(rest), do: rest

  defp drop_first_nl("\n" <> rest), do: rest
  defp drop_first_nl(_), do: ""

  @doc "Follow-up user message for the single automatic repair attempt."
  def build_repair_message(code, error) do
    tail =
      error
      |> repair_error()
      |> String.slice(-2000, 2000)

    """
    Your build123d code failed.

    Error:
    #{tail}

    Code you generated:
    ```python
    #{code}
    ```

    Fix the problem and reply with 1-3 plain sentences plus exactly one
    corrected, complete ```python block that binds the final shape to `part`.
    Follow the gotchas in your instructions (keyword arguments like
    `extrude(amount=...)`, builder-context typing, no Thread primitive,
    sweep-path rule).
    """
    |> String.trim_trailing()
  end

  @doc "Follow-up user message when the previous answer was cut off."
  def build_truncated_repair_message(partial) do
    partial_block =
      if partial do
        """
        What you managed to output:
        ```python
        #{partial}
        ```


        """
      else
        ""
      end

    """
    Your previous answer was cut off before the ```python code block finished (token limit).

    #{partial_block}Return the complete script this time, in exactly one ```python block.
    Keep it under 60 lines: prefer simplified geometry over a heavy sweep when in doubt (e.g. a plain shank instead of a long thread).
    """
    |> String.trim_trailing()
  end

  @doc "Follow-up user message when the new build is geometrically identical to the previous model."
  def build_noop_message(user_message, stats_line) do
    """
    Your new code produced a model identical to the previous one (#{stats_line}) —
    the geometry did not change at all, but the user's request was:

    "#{String.trim(user_message)}"

    Re-read the request, decide which concrete feature it changes, and reply with
    1-3 sentences plus exactly one complete ```python block that binds the final
    shape to `part`. Only if you are certain the user asked to keep the model
    exactly as-is, say so plainly and repeat the code unchanged.
    """
    |> String.trim_trailing()
  end

  @doc "Dialect-aware repair message. Existing 2-arg build123d form is unaffected."
  def build_repair_message(:openscad, code, error) do
    tail =
      error
      |> repair_error()
      |> String.slice(-2000, 2000)

    """
    Your OpenSCAD code failed.

    Error:
    #{tail}

    Code you generated:
    ```python
    #{code}
    ```

    Fix the problem and reply with 1-3 plain sentences plus exactly one
    corrected, complete ```python block whose content is OpenSCAD script
    ending in top-level geometry statements (NEVER `part = union() {...}` —
    geometry cannot be assigned to a variable). Follow the gotchas in your
    instructions (radius discipline, through-holes must overshoot the part,
    no import/include/surface, rotate_extrude profiles at x >= 0).
    """
    |> String.trim_trailing()
  end

  def build_repair_message(:smlibpy, code, error) do
    tail = error |> repair_error() |> String.slice(-2000, 2000)

    """
    Your smlibpy code failed.

    Error:
    #{tail}

    Code you generated:
    ```python
    #{code}
    ```

    Fix the problem and reply with 1-3 plain sentences plus exactly one
    corrected, complete ```python block that binds the final shape to `part`.
    Follow the gotchas in your instructions (no module-level `fuse` — use the
    `+` operator or `part.fuse(other)` method; `fillet`/`chamfer` are methods;
    `ModelingError`/`KernelError` hints explain the fix; list RHS is fine for
    booleans: `part - [a, b]`).
    """
    |> String.trim_trailing()
  end

  def build_repair_message(dialect, code, error) when dialect in [:build123d, nil] do
    build_repair_message(code, error)
  end

  def build_truncated_repair_message(:openscad, partial) do
    partial_block =
      if partial do
        """
        What you managed to output:
        ```python
        #{partial}
        ```


        """
      else
        ""
      end

    """
    Your previous answer was cut off before the ```python code block finished (token limit).

    #{partial_block}Return the complete script this time, in exactly one ```python block.
    End with top-level geometry statements (never `part = union() {...}` — geometry
    cannot be assigned). Keep it under 60 lines: prefer simplified geometry over a
    heavy twist/sweep when in doubt.
    """
    |> String.trim_trailing()
  end

  def build_truncated_repair_message(:smlibpy, partial) do
    build_truncated_repair_message(partial)
  end

  def build_truncated_repair_message(dialect, partial) when dialect in [:build123d, nil] do
    build_truncated_repair_message(partial)
  end

  def build_noop_message(:openscad, user_message, stats_line) do
    """
    Your new code produced a model identical to the previous one (#{stats_line}) —
    the geometry did not change at all, but the user's request was:

    "#{String.trim(user_message)}"

    Re-read the request, decide which concrete feature it changes, and reply with
    1-3 sentences plus exactly one complete ```python block of OpenSCAD script
    ending in top-level geometry statements (never `part = union() {...}`). Only
    if you are certain the user asked to keep the model exactly as-is, say so
    plainly and repeat the code unchanged.
    """
    |> String.trim_trailing()
  end

  def build_noop_message(:smlibpy, user_message, stats_line) do
    build_noop_message(user_message, stats_line)
  end

  def build_noop_message(dialect, user_message, stats_line) when dialect in [:build123d, nil] do
    build_noop_message(user_message, stats_line)
  end

  @doc """
  The on-screen model's numbers as text -- the render may show UI, so the
  model gets the real numbers directly. nil when the engine reported no
  figures (the line is then omitted rather than guessing numbers).
  """
  def current_model_line(%{"bbox_mm" => [x, y, z], "triangles" => tri, "volume_mm3" => vol})
      when is_number(x) and is_number(y) and is_number(z) and is_number(vol) do
    "Current model: bbox #{fmt_number(x)} x #{fmt_number(y)} x #{fmt_number(z)} mm, " <>
      "#{tri(tri)} triangles, volume #{fmt_number(vol)} mm3."
  end

  def current_model_line(_current), do: nil

  @doc """
  Build the current turn's user content. Text-only turns return a plain
  string; image turns return ordered part descriptors:

      [%{type: :text, text: message},
       %{type: :text, text: label},
       %{type: :image_url, data_url: url, media_type: mime},
       ...,
       %{type: :text, text: current_model_line}]

  Order: the user's message, then each labeled image, then the current
  model's numbers (if any). History never carries images.
  """
  def build_user_content(message, images, current)

  # An empty map means "no model on screen" (clients send %{} by default).
  def build_user_content(message, [], current) when current in [nil, %{}],
    do: String.trim(message)

  def build_user_content(message, [], current) do
    case current_model_line(current) do
      nil -> String.trim(message)
      line -> String.trim(message) <> "\n\n" <> line
    end
  end

  def build_user_content(message, images, current) do
    parts = [%{type: :text, text: String.trim(message)}]

    parts =
      Enum.reduce(images, parts, fn img, acc ->
        label =
          cond do
            img[:label] in ["current", :current] -> Prompt.current_render_label()
            img[:label] in ["stl", :stl] -> Prompt.stl_render_label()
            img[:label] in ["earlier", :earlier] -> Prompt.earlier_photo_label()
            true -> Prompt.reference_image_label()
          end

        acc ++ [%{type: :text, text: label}, image_part(img)]
      end)

    line = if current in [nil, %{}], do: nil, else: current_model_line(current)

    case line do
      nil -> parts
      line -> parts ++ [%{type: :text, text: line}]
    end
  end

  @doc """
  Strip any data URL from upstream text -- error strings must never carry
  image bytes (they end up in error_detail shown to / stored by clients).
  """
  def redact_data_urls(text) when is_binary(text) do
    Regex.replace(@data_url_re, text, "data:image/*;base64,[redacted]")
  end

  def redact_data_urls(other), do: other

  @doc "Plain-language stall message; the UI shows elapsed seconds."
  def timeout_message(timeout_s) do
    "the model didn't respond within #{trunc(timeout_s)} s (upstream stall) — " <>
      "try again, or ask for a simpler part"
  end

  @doc """
  The headline for the UI: a traceback's last non-empty line is the exception
  message. Falls back to the whole (single-line) message.
  """
  def error_summary(error)
  def error_summary(nil), do: "unknown error"
  def error_summary(""), do: "unknown error"

  def error_summary(error) do
    lines =
      error
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] -> "unknown error"
      lines -> lines |> List.last() |> String.slice(0, 300)
    end
  end

  # --- internals ---------------------------------------------------------------

  defp matches(re, text) do
    re
    |> Regex.scan(text)
    |> Enum.map(&List.last/1)
  end

  defp count_fences(text), do: text |> String.split("```") |> length() |> Kernel.-(1)

  defp image_part(img) do
    %{
      type: :image_url,
      data_url: img[:data_url] || img["data_url"],
      media_type: img[:media_type] || img["media_type"]
    }
  end

  defp repair_error(nil), do: "unknown error"
  defp repair_error(error) when is_binary(error), do: error

  # %g-style: shortest round-trip-ish representation without trailing zeros
  defp fmt_number(n) when is_integer(n), do: Integer.to_string(n)

  defp fmt_number(n) when is_float(n) do
    n
    |> :erlang.float_to_binary([:compact, {:decimals, 6}])
    |> String.replace(~r/(\.\d*?)0+$/, "\\1")
    |> String.replace(~r/\.$/, "")
  end

  defp tri(n) when is_integer(n), do: n
  defp tri(n) when is_float(n), do: trunc(n)
  defp tri(n) when is_binary(n), do: String.to_integer(n)
end
