defmodule HydraSrt.Youtube.Resolver do
  @moduledoc """
  Contract for turning a YouTube watch URL into a playable HLS playlist URL.

  yt-dlp is only today's way of doing that, so the control plane talks to this
  behaviour and never to a specific tool. Swapping the implementation is a
  config change, not a rewrite.
  """

  @type metadata :: %{
          id: String.t(),
          live: boolean(),
          format_id: String.t() | nil,
          duration: String.t() | nil,
          title: String.t() | nil,
          uploader: String.t() | nil,
          webpage_url: String.t() | nil,
          media_info: map(),
          resolver_version: String.t() | nil
        }

  @type result :: {:ok, String.t(), metadata()} | {:error, atom()}

  @doc """
  Resolves a canonical watch URL to a media playlist URL plus its metadata.

  Errors are reported with implementation-neutral atoms such as
  `:resolver_not_found`, `:resolver_outdated` and `:resolver_timeout`, so
  callers never have to know which tool produced them.
  """
  @callback resolve(String.t(), keyword()) :: result()

  @default_impl HydraSrt.Youtube.ResolverYtDlp

  @spec resolve(String.t(), keyword()) :: result()
  def resolve(url, opts \\ []) when is_binary(url) and is_list(opts) do
    impl().resolve(url, opts)
  end

  @spec impl() :: module()
  def impl do
    :hydra_srt
    |> Application.get_env(:youtube, [])
    |> Keyword.get(:resolver, @default_impl)
  end
end
