defmodule PopcornDemo do
  @moduledoc """
  Browser-side banner for the mnft Popcorn spike.

  Renders VM facts from *inside the browser BEAM* into the page — proving
  unmodified Elixir (supervision tree, Task, ETS, :erlang introspection)
  runs client-side. This is the shape mnft_cad would take in a worker.
  """
  alias Popcorn.JS

  def set_html do
    with :ok <- JS.await_ready() do
      # Prove ETS works: journal a boot record in the GenServer-owned table.
      :ets.insert(:mnft_journal, {:boots, boots() + 1})
      boots = :ets.lookup_element(:mnft_journal, :boots, 2)

      JS.run!("""
        () => {
          const facts = #{facts_json(boots)};
          const el = document.querySelector("#facts");
          el.innerHTML = "";
          for (const [k, v] of Object.entries(facts)) {
            const row = document.createElement("div");
            row.className = "fact";
            const key = document.createElement("span");
            key.className = "k";
            key.textContent = k;
            const val = document.createElement("span");
            val.className = "v";
            val.textContent = v;
            row.append(key, val);
            el.append(row);
          }
          const status = document.querySelector("#status");
          status.textContent = "BEAM is alive in your browser.";
          status.dataset.up = "true";
        }
      """)

      :ok
    end
  end

  defp boots do
    case :ets.lookup(:mnft_journal, :boots) do
      [{:boots, n}] -> n
      [] -> 0
    end
  end

  defp facts_json(boots) do
    %{
      "vm" => "OTP/BEAM (wasm) · Popcorn 1.0",
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "erts" => to_string(:erlang.system_info(:version)),
      "elixir" => System.version(),
      "supervisor" => "PopcornDemo.Supervisor · one_for_one",
      "ets_journal_boots" => boots,
      "next" =>
        "mnft_cad turn pipeline in this VM · replicad dialect kernel in a second worker"
    }
    |> Enum.map(fn {k, v} -> ~s("#{k}": #{json_value(v)}) end)
    |> Enum.join(", ")
    |> then(&"{#{&1}}")
  end

  defp json_value(v) when is_binary(v), do: ~s("#{String.replace(v, ~s("), ~s(\\"))}")
  defp json_value(v) when is_integer(v), do: Integer.to_string(v)
end
