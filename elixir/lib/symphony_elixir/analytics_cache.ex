defmodule SymphonyElixir.AnalyticsCache do
  @moduledoc """
  Shared, debounced cache for full-history analytics window reports.

  A full read of the analytics store plus rollup costs hundreds of
  milliseconds while the dashboard broadcast fires several times per second,
  so every LiveView and the JSON API fetch `Analytics.window_report/2` maps
  through this GenServer instead of recomputing them.

  * Archive files are immutable: each parse is cached under
    `{path, size, mtime}` and reused until that file set changes.
  * The live file is fingerprinted by `{size, mtime}`. When the fingerprint
    moves, reports for all windows are rebuilt from ONE full read + rollup.
  * Recomputes are debounced by the `:analytics_cache_min_recompute_ms`
    application env (default 2000 ms; tests set 0): inside the interval the
    stale report is served even if the fingerprint changed.
  * Raw live-file event lists are only held transiently during a recompute.
    A missing or momentarily unreadable live file yields an empty report —
    the cache never crashes the caller and heals on the next refresh.
  """

  use GenServer

  alias SymphonyElixir.{Analytics, AnalyticsRollup}

  @windows [:h24, :d7, :d30, :all]
  @default_min_recompute_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # Generous call timeout: a recompute grows with history size and must not
  # exit connected LiveViews at the default 5s while it is still bounded work.
  @call_timeout_ms 15_000

  @doc """
  Returns the cached `SymphonyElixir.Analytics.window_report/2` map for `window`.
  """
  @spec report(Analytics.window(), GenServer.server()) :: map()
  def report(window, server \\ __MODULE__) when window in @windows do
    GenServer.call(server, {:report, window}, @call_timeout_ms)
  end

  @impl true
  def init(_opts) do
    {:ok, %{archives: %{}, live_path: nil, live_fingerprint: nil, reports: %{}, recomputed_at_ms: nil}}
  end

  @impl true
  def handle_call({:report, window}, _from, state) do
    {report, state} = fetch_report(window, state)
    {:reply, report, state}
  end

  # Config (analytics path, debounce interval) is read lazily per call, never
  # at init: tests boot the application before pointing env at tmp stores.
  #
  # Order matters: the debounce is checked BEFORE resolving the full analytics
  # path — in production that resolution goes through Config/WorkflowStore
  # (another GenServer call), so it must run at most once per debounce
  # interval, not on every broadcast. The cheap app-env tier alone decides
  # test-driven path swaps, keeping their invalidation immediate.
  defp fetch_report(window, state) do
    env_path = Application.get_env(:symphony_elixir, :analytics_file)

    cond do
      map_size(state.reports) == 0 or (env_path != nil and env_path != state.live_path) ->
        refresh(window, env_path || Analytics.file_path(), state)

      within_debounce?(state) ->
        {Map.fetch!(state.reports, window), state}

      true ->
        live_path = Analytics.file_path()

        if state.live_path == live_path and state.live_fingerprint == fingerprint(live_path) do
          {Map.fetch!(state.reports, window), state}
        else
          refresh(window, live_path, state)
        end
    end
  end

  defp refresh(window, live_path, state) do
    # Fingerprint the live file FIRST: if a rollup --archive-before rotation
    # lands mid-refresh, the stored fingerprint is already stale and the next
    # call recomputes with the rotated file set.
    live_fingerprint = fingerprint(live_path)
    {archive_reads, archives} = archive_reads(live_path, state.archives)
    history = Analytics.merge_history(archive_reads ++ [AnalyticsRollup.read_all_events(live_path)])
    rollup = AnalyticsRollup.rollup(history.events)
    reports = Map.new(@windows, &{&1, Analytics.window_report(&1, history: history, rollup: rollup)})

    state = %{
      state
      | archives: archives,
        live_path: live_path,
        live_fingerprint: live_fingerprint,
        reports: reports,
        recomputed_at_ms: System.monotonic_time(:millisecond)
    }

    {Map.fetch!(reports, window), state}
  rescue
    # A torn concurrent rewrite or unreadable store must never take the
    # dashboard down or blank it: serve the last-known-good report when one
    # exists, and stamp the debounce so persistent failures are not retried
    # on every call.
    _error -> serve_last_known_good(window, state)
  end

  defp serve_last_known_good(window, state) do
    report =
      Map.get(state.reports, window) ||
        Analytics.window_report(window, history: %{events: [], skipped_lines: 0})

    {report, %{state | recomputed_at_ms: System.monotonic_time(:millisecond)}}
  end

  defp archive_reads(live_path, cache) do
    live_path
    |> Analytics.archive_paths()
    |> Enum.map_reduce(%{}, fn path, new_cache ->
      key = {path, fingerprint(path)}
      read = Map.get(cache, key) || AnalyticsRollup.read_all_events(path)
      {read, Map.put(new_cache, key, read)}
    end)
  end

  defp fingerprint(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} -> {size, mtime}
      {:error, reason} -> {:missing, reason}
    end
  end

  defp within_debounce?(%{recomputed_at_ms: recomputed_at_ms}) do
    min_recompute_ms =
      Application.get_env(:symphony_elixir, :analytics_cache_min_recompute_ms, @default_min_recompute_ms)

    System.monotonic_time(:millisecond) - recomputed_at_ms < min_recompute_ms
  end
end
