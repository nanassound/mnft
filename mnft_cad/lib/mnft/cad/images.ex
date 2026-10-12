defmodule Mnft.Cad.Images do
  @moduledoc """
  Uploaded-image validation for a chat turn, ported from the PoC
  (`backend/main.py`).

  Privacy invariant: image BYTES are held in the turn process only -- decoded
  here, passed to the LLM for this single turn, then dropped. They are never
  written to the model store, never persisted, never logged; error strings
  below carry media types and sizes only.
  """

  @max_images_per_turn 3
  @max_image_bytes 4 * 1024 * 1024
  @max_total_image_bytes 8 * 1024 * 1024
  @allowed_mimes ~w(image/jpeg image/png image/webp)

  @data_url_re ~r/\Adata:image\/(jpeg|png|webp);base64,([A-Za-z0-9+\/=]+)\z/
  @thumb_max_bytes 64 * 1024

  @doc """
  Sanitized chat thumbnail for a client photo entry: returns the `thumb`
  data URL when it is a well-formed jpeg/png/webp data URL that decodes to
  at most #{@thumb_max_bytes} bytes, else nil. Thumbs are display-only, so
  an invalid one never fails the turn — the chat bubble just falls back to
  the photo count.
  """
  def thumbnail(img) when is_map(img) do
    url =
      case img[:thumb] || img["thumb"] || "" do
        url when is_binary(url) -> String.trim(url)
        _ -> ""
      end

    case Regex.run(@data_url_re, url) do
      [_, _mime, b64] ->
        with {:ok, raw} <- Base.decode64(b64),
             true <- byte_size(raw) <= @thumb_max_bytes do
          url
        else
          _ -> nil
        end

      nil ->
        nil
    end
  end

  def thumbnail(_), do: nil

  @doc """
  Validate every image up front; never silently drop one.

  Returns `{:ok, [%{data_url, label, media_type, bytes, size, thumb}]}` or
  `{:error, reason}` with an indexed, user-safe message.
  """
  def validate(nil), do: {:ok, []}
  def validate([]), do: {:ok, []}

  def validate(images) when is_list(images) do
    with :ok <- check_count(images),
         {:ok, out} <- validate_each(images, 0, [], 0) do
      {:ok, out}
    end
  end

  defp check_count(images) when length(images) > @max_images_per_turn do
    {:error, "images: #{length(images)} attached, limit is #{@max_images_per_turn} per turn"}
  end

  defp check_count(_images), do: :ok

  defp validate_each([], _i, out, _total), do: {:ok, Enum.reverse(out)}

  defp validate_each([img | rest], i, out, total) do
    label = "images[#{i}]"
    url = data_url(img) |> String.trim()

    with {:ok, media_type, b64} <- match_data_url(url, label),
         {:ok, raw} <- decode_base64(b64, label),
         :ok <- check_size(raw, label),
         :ok <- check_total(total + byte_size(raw)) do
      entry = %{
        data_url: url,
        label: label_of(img),
        media_type: media_type,
        bytes: raw,
        size: byte_size(raw),
        thumb: thumbnail(img)
      }

      validate_each(rest, i + 1, [entry | out], total + byte_size(raw))
    end
  end

  defp data_url(img) when is_map(img), do: img[:data_url] || img["data_url"] || ""
  defp data_url(_img), do: ""

  defp label_of(img) when is_map(img), do: img[:label] || img["label"] || "reference"
  defp label_of(_img), do: "reference"

  defp match_data_url(url, label) do
    case Regex.run(@data_url_re, url) do
      [_, mime, b64] -> {:ok, "image/" <> mime, b64}
      nil -> {:error, data_url_error(url, label)}
    end
  end

  # Error messages mirror the PoC's diagnosis order: not a data URL, not
  # base64-shaped, unsupported media type, then invalid base64 payload.
  defp data_url_error(url, label) do
    {head, sep, b64} = split_at_comma(url)
    mime = head |> String.trim_leading("data:") |> String.split(";") |> List.first()

    cond do
      not String.starts_with?(url, "data:") ->
        "#{label}: must be a data:image/(jpeg|png|webp);base64 URL"

      sep == "" or not String.ends_with?(head, ";base64") or b64 == "" ->
        "#{label}: data URL must be base64-encoded (data:image/(jpeg|png|webp);base64,...)"

      mime not in @allowed_mimes ->
        "#{label}: unsupported media type #{mime_or_unknown(mime)} " <>
          "(allowed: image/jpeg, image/png, image/webp)"

      true ->
        "#{label}: payload is not valid base64"
    end
  end

  defp mime_or_unknown(""), do: "unknown"
  defp mime_or_unknown(mime), do: mime

  defp decode_base64(b64, label) do
    case Base.decode64(b64) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, "#{label}: payload is not valid base64"}
    end
  end

  defp check_size(raw, label) do
    if byte_size(raw) > @max_image_bytes do
      {:error,
       "#{label}: decoded image is #{mb(byte_size(raw))} MB, over the #{div(@max_image_bytes, 1024 * 1024)} MB per-image limit"}
    else
      :ok
    end
  end

  defp check_total(total) do
    if total > @max_total_image_bytes do
      {:error,
       "images: decoded total is #{mb(total)} MB, over the #{div(@max_total_image_bytes, 1024 * 1024)} MB per-turn limit"}
    else
      :ok
    end
  end

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)

  defp split_at_comma(url) do
    case String.split(url, ",", parts: 2) do
      [head, b64] -> {head, ",", b64}
      [head] -> {head, "", ""}
    end
  end
end
