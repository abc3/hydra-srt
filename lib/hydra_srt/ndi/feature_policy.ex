defmodule HydraSrt.Ndi.FeaturePolicy do
  @moduledoc """
  Single reader for NDI rollout flags under `Application.get_env(:hydra_srt, :ndi, [])`.

  Keys: `:enabled`, `:receive`, `:send` — all default `false`. No other module should
  read that env key directly.
  """

  @type action :: :enabled | :receive | :send | :discovery
  @type flag_key :: :enabled | :receive | :send
  @type deny_reason :: String.t()

  @spec enabled?() :: boolean()
  def enabled? do
    flag?(:enabled)
  end

  @spec receive?() :: boolean()
  def receive? do
    enabled?() and flag?(:receive)
  end

  @spec send?() :: boolean()
  def send? do
    enabled?() and flag?(:send)
  end

  @doc """
  Returns a stable deny reason when the requested action is not allowed, or `nil` when allowed.

  Reasons:
  - `"NDI_DISABLED"` — master flag off, or directional receive/send not permitted
  """
  @spec deny_reason(action()) :: deny_reason() | nil
  def deny_reason(:enabled) do
    if enabled?(), do: nil, else: "NDI_DISABLED"
  end

  def deny_reason(:discovery) do
    deny_reason(:enabled)
  end

  def deny_reason(:receive) do
    if receive?(), do: nil, else: "NDI_DISABLED"
  end

  def deny_reason(:send) do
    if send?(), do: nil, else: "NDI_DISABLED"
  end

  @spec flag?(flag_key()) :: boolean()
  def flag?(key) when key in [:enabled, :receive, :send] do
    :hydra_srt
    |> Application.get_env(:ndi, [])
    |> Keyword.get(key, false)
    |> truthy?()
  end

  @spec truthy?(term()) :: boolean()
  def truthy?(true), do: true
  def truthy?(false), do: false
  def truthy?(_), do: false
end
