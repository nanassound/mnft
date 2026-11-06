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

  defp apply_op(%{"op" => "prism", "n" => n, "r" => r, "h" => h} = op, stack, _i) do
    rot = deg_to_rad(Map.get(op, "rot", 0))

    with {:ok, face} <- regular_ngon_face(n, r, rot),
         {:ok, shape} <- OCEx.extrude(face, {0.0, 0.0, h * 1.0}),
         {:ok, shape} <- place(shape, op) do
      {:ok, [shape | stack]}
    end
  end

  # Sketch-layer seed: `polygon` pushes a planar n-gon FACE; `extrude` turns a
  # face into a solid. Named solids like `prism` are sugar over this pair.
  defp apply_op(%{"op" => "polygon", "n" => n, "r" => r} = op, stack, _i) do
    rot = deg_to_rad(Map.get(op, "rot", 0))

    with {:ok, face} <- regular_ngon_face(n, r, rot),
         {:ok, face} <- place(face, op) do
      {:ok, [face | stack]}
    end
  end

  # `polyline` pushes a planar FACE through the points when `close` (default
  # true); `close: false` keeps an open WIRE — a sweep path.
  defp apply_op(%{"op" => "polyline", "pts" => pts} = op, stack, _i) do
    close? = Map.get(op, "close", true)
    vertices = for [x, y, z] <- pts, do: {x, y, z}

    with {:ok, wire} <- polyline_wire(vertices, close?),
         {:ok, pushed} <- close_or_wire(wire, close?),
         {:ok, pushed} <- place(pushed, op) do
      {:ok, [pushed | stack]}
    end
  end

  defp polyline_wire(vertices, true), do: closed_wire(vertices)
  defp polyline_wire(vertices, false), do: open_wire(vertices)

  defp close_or_wire(wire, true), do: OCEx.face(wire)
  defp close_or_wire(wire, false), do: {:ok, wire}

  defp apply_op(%{"op" => "extrude", "h" => h} = op, [top | rest], i) do
    [dx, dy, dz] = Map.get(op, "dir", [0, 0, 1])
    len = :math.sqrt(dx * dx + dy * dy + dz * dz)

    with {:ok, solid} <- OCEx.extrude(top, {dx / len * h, dy / len * h, dz / len * h}) do
      {:ok, [solid | rest]}
    else
      {:error, reason} ->
        {:error,
         "ocex: op #{i}: extrude needs a planar face on the stack (#{inspect(reason)})"}
    end
  end

  defp apply_op(%{"op" => "extrude"}, [], i),
    do: {:error, "ocex: op #{i}: extrude needs a face on the stack (stack is empty)"}

  defp apply_op(%{"op" => "rotate", "axis" => [x, y, z], "degrees" => degrees}, [top | rest], i) do
    with {:ok, shape} <- OCEx.rotate(top, {0.0, 0.0, 0.0}, {x, y, z}, degrees * 1.0) do
      {:ok, [shape | rest]}
    else
      {:error, reason} -> {:error, "ocex: op #{i}: rotate failed (#{inspect(reason)})"}
    end
  end

  defp apply_op(%{"op" => "rotate"}, [], i),
    do: {:error, "ocex: op #{i}: rotate needs a shape on the stack (stack is empty)"}

  # --- sketch helpers ----------------------------------------------------------

  # Regular n-gon in the XY plane, circumradius r, centred on the origin,
  # first vertex at angle `rot`. Returns a planar face.
  defp regular_ngon_face(n, r, rot) do
    step = 2 * :math.pi() / n

    vertices =
      for k <- 0..(n - 1) do
        angle = rot + k * step
        {r * :math.cos(angle), r * :math.sin(angle), 0.0}
      end

    with {:ok, wire} <- closed_wire(vertices), do: OCEx.face(wire)
  end

  defp closed_wire(vertices) do
    chain_wire(Enum.zip(vertices, tl(vertices) ++ [hd(vertices)]))
  end

  defp open_wire(vertices), do: chain_wire(Enum.zip(vertices, tl(vertices)))

  defp chain_wire(pairs) do
    edges =
      Enum.reduce_while(pairs, {:ok, []}, fn {a, b}, {:ok, acc} ->
        case OCEx.edge(a, b) do
          {:ok, edge} -> {:cont, {:ok, [edge | acc]}}
          {:error, _msg} = error -> {:halt, error}
        end
      end)

    with {:ok, edges} <- edges, do: OCEx.wire(Enum.reverse(edges))
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

  defp deg_to_rad(degrees) when is_number(degrees), do: degrees * :math.pi() / 180
end
