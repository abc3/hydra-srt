defmodule HydraSrt.Youtube.RefreshScheduler do
  @moduledoc "Schedules jittered YouTube resolver refresh notifications."

  use GenServer

  alias HydraSrt.Youtube.Url

  @default_jitter_ms :timer.seconds(30)
  @minimum_delay_ms :timer.seconds(30)
  @safety_margin_ms :timer.minutes(10)

  @type state :: %{timers: %{String.t() => reference()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec schedule(String.t(), keyword()) :: :ok | {:error, :invalid_url}
  def schedule(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case Url.canonicalize(url) do
      {:ok, canonical} ->
        server = Keyword.get(opts, :server, __MODULE__)

        if is_pid(GenServer.whereis(server)) do
          GenServer.cast(server, {:schedule, canonical, opts})
        end

        :ok

      _ ->
        {:error, :invalid_url}
    end
  end

  @spec cancel(String.t(), GenServer.server()) :: :ok
  def cancel(url, server \\ __MODULE__) when is_binary(url) do
    case Url.canonicalize(url) do
      {:ok, canonical} ->
        if is_pid(GenServer.whereis(server)), do: GenServer.cast(server, {:cancel, canonical})
        :ok

      _ ->
        :ok
    end
  end

  @spec init(keyword()) :: {:ok, state()}
  def init(_opts), do: {:ok, %{timers: %{}}}

  @spec handle_cast({:schedule, String.t(), keyword()} | {:cancel, String.t()}, state()) ::
          {:noreply, state()}
  def handle_cast({:schedule, canonical, opts}, state) do
    state = cancel_timer(state, canonical)
    delay = delay_ms(opts)
    timer = Process.send_after(self(), {:refresh, canonical}, delay)
    {:noreply, %{state | timers: Map.put(state.timers, canonical, timer)}}
  end

  def handle_cast({:cancel, canonical}, state), do: {:noreply, cancel_timer(state, canonical)}

  @spec handle_info({:refresh, String.t()}, state()) :: {:noreply, state()}
  def handle_info({:refresh, canonical}, state) do
    Phoenix.PubSub.broadcast(HydraSrt.PubSub, "youtube:refresh", {:youtube_refresh, canonical})
    {:noreply, %{state | timers: Map.delete(state.timers, canonical)}}
  end

  @spec delay_ms(keyword()) :: pos_integer()
  def delay_ms(opts) do
    case Keyword.get(opts, :delay_ms) do
      delay when is_integer(delay) and delay > 0 -> delay
      _ -> calculated_delay(opts)
    end
  end

  @spec calculated_delay(keyword()) :: pos_integer()
  def calculated_delay(opts) do
    expires_at = Keyword.get(opts, :expires_at) || expires_at_from_uri(Keyword.get(opts, :uri))

    base =
      if is_integer(expires_at),
        do:
          max(@minimum_delay_ms, expires_at - now_seconds() - div(@safety_margin_ms, 1_000)) *
            1_000,
        else: @minimum_delay_ms

    jitter = Keyword.get(opts, :jitter_ms, @default_jitter_ms)
    max(@minimum_delay_ms, base + jitter_value(jitter))
  end

  @spec expires_at_from_uri(String.t() | nil) :: integer() | nil
  def expires_at_from_uri(uri), do: HydraSrt.Youtube.Cache.expires_at(uri)

  @spec now_seconds() :: integer()
  def now_seconds, do: System.system_time(:second)

  @spec jitter_value(integer()) :: integer()
  def jitter_value(jitter) when is_integer(jitter) and jitter > 0 do
    :rand.uniform(jitter * 2 + 1) - jitter - 1
  end

  def jitter_value(_jitter), do: 0

  @spec cancel_timer(state(), String.t()) :: state()
  def cancel_timer(state, canonical) do
    case state.timers[canonical] do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    %{state | timers: Map.delete(state.timers, canonical)}
  end
end
