defmodule Mnft.Cad.StoreJournalDisableTest do
  @moduledoc """
  `config :mnft_cad, :cad, journal: false` (the browser-embedder mode): no
  `Mnft.Cad.Journal` process exists and sessions/turns round-trip purely in
  ETS. Runs with `async: false` because it restarts the whole `:mnft_cad`
  application under swapped config.
  """

  use ExUnit.Case, async: false

  setup_all do
    original = Application.get_env(:mnft_cad, :cad)

    Application.put_env(:mnft_cad, :cad, Keyword.put(original || [], :journal, false))
    Application.stop(:mnft_cad)
    {:ok, _} = Application.ensure_all_started(:mnft_cad)

    on_exit(fn ->
      Application.put_env(:mnft_cad, :cad, original)
      Application.stop(:mnft_cad)
      {:ok, _} = Application.ensure_all_started(:mnft_cad)
    end)

    :ok
  end

  test "no Journal process is started" do
    assert Process.whereis(Mnft.Cad.Journal) == nil
  end

  test "sessions and turns still round-trip in memory" do
    owner = "journal-disabled-#{System.unique_integer([:positive])}"
    {:ok, session} = Mnft.Cad.create_session(owner)

    {:ok, turn} =
      Mnft.Cad.record_turn(
        session,
        %{content: "a 40 mm hex pen holder", meta: %{}},
        %{content: "Here it is.", code: "part = Box(1, 1, 1)", meta: %{}},
        %{id: "m-journal-off", mesh: %{"triangles" => 12, "volume_mm3" => 1.0}, has_glb: false}
      )

    assert turn.user_message.content == "a 40 mm hex pen holder"
    assert turn.assistant_message.content == "Here it is."

    contents =
      session.id |> Mnft.Cad.list_messages() |> Enum.map(& &1.content)

    assert contents == ["a 40 mm hex pen holder", "Here it is."]

    assert %{id: "m-journal-off", mesh: %{"triangles" => 12}} =
             Mnft.Cad.latest_model(session.id)
  end
end
