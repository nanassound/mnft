defmodule Mnft.Cad.Jido do
  @moduledoc """
  The Jido instance owning one agent server per CAD session
  (`"cad_session:<session_id>"`).
  """
  use Jido, otp_app: :mnft_cad
end
