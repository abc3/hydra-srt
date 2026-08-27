defmodule HydraSrt.Youtube.FeaturePolicy do
  @moduledoc "Single reader for the YouTube feature flag."

  @type action :: :enabled

  @spec enabled?() :: boolean()
  def enabled? do
    configured_flag(:enabled)
  end

  @spec deny_reason(action()) :: String.t() | nil
  def deny_reason(:enabled) do
    if enabled?(), do: nil, else: "YOUTUBE_DISABLED"
  end

  @spec flag?(action()) :: boolean()
  def flag?(:enabled), do: enabled?()

  @spec configured_flag(action()) :: boolean()
  def configured_flag(:enabled) do
    configured = Application.get_env(:hydra_srt, :youtube, [])

    case Keyword.fetch(configured, :enabled) do
      {:ok, value} -> truthy?(value)
      :error -> env_flag(System.get_env("YOUTUBE_ENABLED"))
    end
  end

  @spec env_flag(String.t() | nil) :: boolean()
  def env_flag(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  def env_flag(_value), do: false

  @spec truthy?(term()) :: boolean()
  def truthy?(true), do: true
  def truthy?(value) when is_binary(value), do: env_flag(value)
  def truthy?(_value), do: false
end
