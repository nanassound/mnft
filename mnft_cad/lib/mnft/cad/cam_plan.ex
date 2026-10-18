defmodule Mnft.Cad.CamPlan do
  @moduledoc """
  Validation for the LLM-emitted CNC machining plan (the `cam` JSON block).

  Schema (strict — unknown keys rejected):

      {"material": "wood" | "aluminum",
       "ops": [{"op": "face" | "pocket" | "profile" | "drill",
                "toolbit": "<id>", "peck_mm": <optional positive number>}]}

  `toolbit` ids must exist in `priv/cam/toolbits.json` (the machine-side
  truth: vendored .fctb geometry + feeds). This module stays FreeCAD-free —
  the geometry is only read inside FreeCAD, by the worker.

  Validation failure is non-fatal upstream: the model still lands, the chat
  gets a "CAM plan rejected: ..." note and no G-code is produced.
  """

  @materials ~w(wood aluminum)
  @ops ~w(face pocket profile drill)
  @op_keys ~w(op toolbit peck_mm)

  @doc "Path of the toolbits config (machine block + id -> fctb + feeds)."
  def toolbits_path, do: Application.app_dir(:mnft_cad, "priv/cam/toolbits.json")

  @doc """
  Decoded toolbits.json, read per call. `{:ok, map}` or `{:error, msg}`;
  a broken file must degrade CAM, never the turn.
  """
  def toolbits do
    case File.read(toolbits_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:error, reason} -> {:error, "toolbits.json is not valid JSON: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "toolbits.json unreadable: #{inspect(reason)}"}
    end
  end

  @doc "Validated toolbit ids (sorted), for the prompt's CAM section."
  def toolbit_ids do
    case toolbits() do
      {:ok, %{"toolbits" => tools}} when is_map(tools) ->
        Map.keys(tools) |> Enum.sort()

      _ ->
        []
    end
  end

  @doc "Validate a decoded plan against the decoded toolbits config."
  def validate(plan, toolbits)

  def validate(%{"material" => _} = plan, %{"toolbits" => known}) when is_map(known) do
    with :ok <- material(plan),
         :ok <- ops(plan, known) do
      {:ok, plan}
    end
  end

  def validate(_plan, _toolbits), do: {:error, "plan must be an object with 'material' and 'ops'"}

  defp material(%{"material" => m}) when m in @materials, do: :ok

  defp material(%{"material" => m}),
    do: {:error, "material must be one of #{Enum.join(@materials, ", ")}; got #{inspect(m)}"}

  defp ops(%{"ops" => ops}, known) when is_list(ops) do
    if ops == [] do
      {:error, "ops must not be empty (omit the whole cam block instead)"}
    else
      ops
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {op, i}, :ok ->
        case validate_op(op, known) do
          :ok -> {:cont, :ok}
          {:error, msg} -> {:halt, {:error, "op #{i}: #{msg}"}}
        end
      end)
    end
  end

  defp ops(%{"ops" => other}, _known),
    do: {:error, "ops must be a list; got #{inspect(other)}"}

  defp ops(_plan, _known), do: {:error, "plan is missing 'ops'"}

  defp validate_op(op, known) when is_map(op) do
    unknown = Map.keys(op) -- @op_keys

    cond do
      unknown != [] ->
        {:error, "unknown keys #{inspect(unknown)} (allowed: #{Enum.join(@op_keys, ", ")})"}

      not Map.has_key?(op, "op") ->
        {:error, "missing 'op'"}

      op["op"] not in @ops ->
        {:error, "'op' must be one of #{Enum.join(@ops, ", ")}; got #{inspect(op["op"])}"}

      not Map.has_key?(op, "toolbit") ->
        {:error, "missing 'toolbit'"}

      not is_binary(op["toolbit"]) ->
        {:error, "'toolbit' must be a string id"}

      not Map.has_key?(known, op["toolbit"]) ->
        {:error, "unknown toolbit #{inspect(op["toolbit"])}"}

      peck_bad?(op["peck_mm"]) ->
        {:error, "'peck_mm' must be a positive number"}

      true ->
        :ok
    end
  end

  defp validate_op(op, _known), do: {:error, "each op must be an object; got #{inspect(op)}"}

  defp peck_bad?(nil), do: false
  defp peck_bad?(v) when is_number(v) and v > 0, do: false
  defp peck_bad?(_), do: true
end
