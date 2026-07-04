defmodule SymphonyElixir.PhaseEventScanner do
  @moduledoc """
  Derives Phase Artifact Protocol analytics events from issue comments.

  The orchestrator casts `scan/1` at dispatch/completion choke points; the
  scanner fetches the issue's tracker comments, derives phase events via
  `SymphonyElixir.PhaseEvents.derive/1`, and appends events it has not emitted
  before to the analytics store. Event ids are deterministic, so read-side
  dedup covers restarts; the in-process MapSet only avoids duplicate writes
  within one scanner lifetime.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Analytics, PhaseEvents, Tracker}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fire-and-forget scan request. Silently no-ops when the scanner is not running.
  """
  @spec scan(term(), GenServer.server()) :: :ok
  def scan(issue, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      server_ref -> GenServer.cast(server_ref, {:scan, issue})
    end
  end

  @doc """
  Synchronous scan used by tests to avoid sleeping on the async cast.
  """
  @spec scan_now(term(), GenServer.server()) :: :ok
  def scan_now(issue, server \\ __MODULE__) do
    GenServer.call(server, {:scan, issue})
  end

  @impl true
  def init(_opts) do
    {:ok, MapSet.new()}
  end

  @impl true
  def handle_cast({:scan, issue}, emitted_event_ids) do
    {:noreply, scan_issue(issue, emitted_event_ids)}
  end

  @impl true
  def handle_call({:scan, issue}, _from, emitted_event_ids) do
    {:reply, :ok, scan_issue(issue, emitted_event_ids)}
  end

  defp scan_issue(issue, emitted_event_ids) do
    case issue_field(issue, :id) do
      nil -> emitted_event_ids
      issue_id -> scan_issue_comments(issue, issue_id, emitted_event_ids)
    end
  rescue
    error ->
      Logger.warning("phase event scan failed for #{issue_context(issue)}: #{Exception.message(error)}")
      emitted_event_ids
  end

  defp scan_issue_comments(issue, issue_id, emitted_event_ids) do
    case Tracker.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        record_new_events(issue, comments, emitted_event_ids)

      {:error, reason} ->
        Logger.warning("phase event scan failed for #{issue_context(issue)}: #{inspect(reason)}")
        emitted_event_ids
    end
  end

  defp record_new_events(issue, comments, emitted_event_ids) do
    new_events =
      comments
      |> PhaseEvents.derive()
      |> Enum.reject(&MapSet.member?(emitted_event_ids, &1.event_id))

    Enum.each(new_events, fn event ->
      event
      |> Map.merge(%{
        issue_id: issue_field(issue, :id),
        issue_identifier: issue_field(issue, :identifier),
        issue_url: issue_field(issue, :url),
        source: "phase_scan"
      })
      |> Analytics.record_event()
    end)

    MapSet.union(emitted_event_ids, MapSet.new(new_events, & &1.event_id))
  end

  defp issue_field(issue, key) when is_map(issue), do: Map.get(issue, key)
  defp issue_field(_issue, _key), do: nil

  defp issue_context(issue) do
    "issue_id=#{issue_field(issue, :id) || "n/a"} issue_identifier=#{issue_field(issue, :identifier) || "n/a"}"
  end
end
