defmodule Mnft.Cad.Config do
  @moduledoc """
  Read access to the `:mnft_cad, :cad` configuration tree.

  Keys: `:store`, `:engine`, `:llm_module`, `:events`, `:models_dir`,
  `:data_dir`, `:worker_python`, `:worker_cwd`, `:exec_concurrency`,
  `:exec_timeout_s`, `:turn_budget_s`, `:openscad`, `:llm` (keyword:
  `:provider`, `:base_url`, `:api_key`, `:text_model`, `:vision_model`,
  `:timeout_s`, `:max_tokens`, `:repair_max_rounds`), `:references`
  (keyword: `:pdftoppm_bin`, `:pdftotext_bin`, `:fetch_timeout_s`,
  `:max_pdf_mb`, `:max_pages`, `:pdf_dpi`, `:python_bin`, `:max_text_chars`,
  `:max_urls_per_turn`), `:references_module` and `:references_fetch_fun`
  (test seams), `:stl` (keyword: `:python_bin`, `:max_stl_mb`,
  `:max_block_chars`) and `:stl_profile_fun` (test seam).
  """

  @spec all() :: keyword()
  def all, do: :mnft_cad |> Application.get_env(:cad, []) |> Keyword.new()

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)

  @spec llm() :: keyword()
  def llm, do: get(:llm, []) |> Keyword.new()
end
