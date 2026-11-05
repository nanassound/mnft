defmodule MnftOcex.Interpreter do
  @moduledoc """
  Executes a validated `ocex` op list against OCEx as a shape stack.

  Every op returns `{:ok, stack}` or `{:error, message}`; the message carries
  the op index so the repair loop can point the model at the failing step.
  OCEx itself never raises through this module — every call is a tagged
  tuple, and any unexpected exception belongs to the engine's containment.
  """

  @spec run([map()]) :: {:ok, term()} | {:error, String.t()}
  def run(ops) when is_list(ops) do
    ops
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {op, i}, {:ok, stack} ->
      case apply_op(op, stack, i) do
        {:ok, stack} -> {:cont, {:ok, stack}}
        {:error, _msg} = error -> {:halt, error}
      end
    end)
    |> finish()
  end

  defp finish({:ok, [shape]}), do: {:ok, shape}

  defp finish({:ok, stack}),
    do:
      {:error,
       "ocex: program must end with exactly one shape on the stack (got #{length(stack)})"}

  defp finish({:error, _msg} = error), do: error

  # --- primitives --------------------------------------------------------------

  defp apply_op(%{"op" => "box", "size" => [x, y, z]} = op, stack, _i) do
    with {:ok, shape} <- OCEx.box(x, y, z),
         {:ok, shape} <- place(shape, op) do
      {:ok, [shape | stack]}
    end
  end

  defp apply_op(%{"op" => "cylinder", "r" => r, "h" => h} = op, stack, _i) do
    with {:ok, shape} <- OCEx.cylinder(r, h),
         {:ok, shape} <- place(shape, op) do
      {:ok, [shape | stack]}
    end
  end

  defp apply_op(%{"op" => "sphere", "r" => r} = op, stack, _i) do
    with {:ok, shape} <- OCEx.sphere(r),
         {:ok, shape} <- place(shape, op) do
      {:ok, [shape | stack]}
    end
  end

  # --- transforms --------------------------------------------------------------

  defp apply_op(%{"op" => "translate", "delta" => [dx, dy, dz]}, [top | rest], _i) do
    with {:ok, shape} <- OCEx.translate(top, {dx, dy, dz}) do
      {:ok, [shape | rest]}
    end
  end

  defp apply_op(%{"op" => "translate"}, [], i),
    do: {:error, "ocex: op #{i}: translate needs a shape on the stack (stack is empty)"}

  defp apply_op(%{"op" => "translate", "delta" => other}, _stack, i),
    do: {:error, "ocex: op #{i}: translate delta must be [dx, dy, dz], got #{inspect(other)}"}

  defp apply_op(%{"op" => "fillet_all", "r" => r}, [top | rest], i) do
    with {:ok, edges} <- OCEx.edges(top),
         {:ok, shape} <- OCEx.fillet(top, edges, r) do
      {:ok, [shape | rest]}
    else
      {:error, reason} ->
        {:error, "ocex: op #{i}: fillet_all failed (#{inspect(reason)})"}
    end
  end

  defp apply_op(%{"op" => "fillet_all"}, [], i),
    do: {:error, "ocex: op #{i}: fillet_all needs a shape on the stack (stack is empty)"}

  # --- booleans ----------------------------------------------------------------

  defp apply_op(%{"op" => "cut"}, [tool, blank | rest], i) do
    with {:ok, shape} <- OCEx.cut(blank, tool) do
      {:ok, [shape | rest]}
    else
      {:error, reason} -> {:error, "ocex: op #{i}: cut failed (#{inspect(reason)})"}
    end
  end

  defp apply_op(%{"op" => "cut"}, stack, i),
    do: {:error, "ocex: op #{i}: cut needs a blank and a tool on the stack (got #{length(stack)})"}

  defp apply_op(%{"op" => "union"}, [tool, blank | rest], i) do
    with {:ok, shape} <- OCEx.fuse(blank, tool) do
      {:ok, [shape | rest]}
    else
      {:error, reason} -> {:error, "ocex: op #{i}: union failed (#{inspect(reason)})"}
    end
  end

  defp apply_op(%{"op" => "union"}, stack, i),
    do: {:error, "ocex: op #{i}: union needs two shapes on the stack (got #{length(stack)})"}

  defp apply_op(%{"op" => "intersect"}, [tool, blank | rest], i) do
    with {:ok, shape} <- OCEx.common(blank, tool) do
      {:ok, [shape | rest]}
    else
      {:error, reason} -> {:error, "ocex: op #{i}: intersect failed (#{inspect(reason)})"}
    end
  end

  defp apply_op(%{"op" => "intersect"}, stack, i),
    do:
      {:error,
       "ocex: op #{i}: intersect needs two shapes on the stack (got #{length(stack)})"}

  defp apply_op(op, _stack, i),
    do:
      {:error,
       "ocex: op #{i}: malformed op #{inspect(op)} (validation should have rejected this)"}

  # --- helpers -----------------------------------------------------------------

  defp place(shape, op) do
    case Map.fetch(op, "at") do
      {:ok, [x, y, z]} -> OCEx.translate(shape, {x, y, z})
      :error -> {:ok, shape}
    end
  end
end
