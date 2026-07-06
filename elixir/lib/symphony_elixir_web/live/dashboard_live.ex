defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{AnalyticsCache, Config}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, PeerStatus, Presenter}
  @runtime_tick_ms 1_000
  @snapshot_retry_max_ms 30_000
  @peer_poll_every_ticks 5
  @analytics_windows %{"h24" => :h24, "d7" => :d7, "d30" => :d30, "all" => :all}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    socket =
      socket
      |> assign(:snapshot_retry_ref, nil)
      |> assign(:snapshot_retry_delay_ms, nil)
      |> assign(:analytics_window, :all)
      |> assign(:tick_count, 0)
      |> assign(:peer_urls, Config.peer_dashboards())
      |> assign(:peers, %{})
      |> load_snapshot()
      |> poll_peers()

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    tick_count = socket.assigns.tick_count + 1

    socket =
      socket
      |> assign(:tick_count, tick_count)
      |> assign(:now, DateTime.utc_now())

    socket = if rem(tick_count, @peer_poll_every_ticks) == 0, do: poll_peers(socket), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, load_snapshot(socket)}
  end

  @impl true
  def handle_info(:retry_snapshot, socket) do
    {:noreply, load_snapshot(socket)}
  end

  @impl true
  def handle_event("analytics_window", %{"window" => window}, socket) do
    case Map.fetch(@analytics_windows, window) do
      {:ok, window_atom} ->
        socket =
          socket
          |> assign(:analytics_window, window_atom)
          |> assign(:report, AnalyticsCache.report(window_atom))

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:peer_fetch, url}, result, socket) do
    peer_result =
      case result do
        {:ok, fetch_result} -> fetch_result
        {:exit, reason} -> {:error, {:exit, reason}}
      end

    socket = update(socket, :peers, &Map.put(&1, url, peer_result))
    {:noreply, assign_page_title(socket)}
  end

  @impl true
  def render(assigns) do
    peer_payloads = peer_payloads(assigns.peer_urls, assigns.peers)

    assigns =
      assigns
      |> assign(:multi?, assigns.peer_urls != [])
      |> assign(:peer_payloads, peer_payloads)
      |> assign(:combined, combined_counts(assigns.payload, peer_payloads))

    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div>
          <p class="eyebrow">
            Symphony Observability
          </p>
          <h1 class="hero-title">
            Operations Dashboard
          </h1>
          <p class="instance-chip instance-chip-header">
            <span class="instance-name"><%= instance_label(instance_of(@payload)) %></span>
            <span :if={instance_of(@payload).mode == "maestro"} class="mode-badge">maestro</span>
          </p>
        </div>

        <div class="status-cluster">
          <span class="status-stack" role="status">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-reconnecting">
              <span class="status-badge-dot"></span>
              Reconnecting
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </span>
          <.freshness_indicator payload={@payload} now={@now} />
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
          <p class="error-copy">Retrying automatically…</p>
        </section>
      <% else %>
        <section :if={@multi?} class="instance-strip">
          <.instance_card :for={card <- instance_cards(@payload, @peer_urls, @peers, @now)} card={card} />
        </section>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @combined.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @combined.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @combined.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(combined_tokens(@payload, @peer_payloads).total) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(combined_tokens(@payload, @peer_payloads).input) %> / Out <%= format_int(combined_tokens(@payload, @peer_payloads).output) %>
            </p>
            <p class="metric-detail"><%= since_start_text(@multi?) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(combined_runtime_seconds(@payload, @peer_payloads, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions. <%= since_start_text(@multi?) %></p>
          </article>

          <.rate_limit_card payload={@payload} peer_payloads={@peer_payloads} now={@now} />
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if merged_rows(@payload, @peer_payloads, :running) == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col :if={@multi?} style="width: 7rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th :if={@multi?}>Instance</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- merged_rows(@payload, @peer_payloads, :running)}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={json_details_href(entry)}>JSON details</a>
                      </div>
                    </td>
                    <td :if={@multi?}><span class="instance-chip"><%= entry.instance_name %></span></td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <.copy_session_id session_id={entry.session_id} />
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section :if={@combined.blocked > 0} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title section-title-danger">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table" style="min-width: 760px;">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th :if={@multi?}>Instance</th>
                  <th>State</th>
                  <th>Session</th>
                  <th>Blocked at</th>
                  <th>Last update</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- merged_rows(@payload, @peer_payloads, :blocked)}>
                  <td>
                    <div class="issue-stack">
                      <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                      <a class="issue-link" href={json_details_href(entry)}>JSON details</a>
                    </div>
                  </td>
                  <td :if={@multi?}><span class="instance-chip"><%= entry.instance_name %></span></td>
                  <td>
                    <span class={state_badge_class(entry.state || "Blocked")}>
                      <%= entry.state || "Blocked" %>
                    </span>
                  </td>
                  <td>
                    <.copy_session_id session_id={entry.session_id} />
                  </td>
                  <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                  <td>
                    <div class="detail-stack">
                      <span
                        class="event-text"
                        title={entry.last_message || to_string(entry.last_event || "n/a")}
                      ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                      <span class="muted event-meta">
                        <%= entry.last_event || "n/a" %>
                        <%= if entry.last_event_at do %>
                          · <span class="mono numeric"><%= entry.last_event_at %></span>
                        <% end %>
                      </span>
                    </div>
                  </td>
                  <td><%= entry.error || "n/a" %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section :if={@combined.retrying > 0} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table" style="min-width: 680px;">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th :if={@multi?}>Instance</th>
                  <th>Attempt</th>
                  <th>Due at</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- merged_rows(@payload, @peer_payloads, :retrying)}>
                  <td>
                    <div class="issue-stack">
                      <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                      <a class="issue-link" href={json_details_href(entry)}>JSON details</a>
                    </div>
                  </td>
                  <td :if={@multi?}><span class="instance-chip"><%= entry.instance_name %></span></td>
                  <td>
                    <span class={state_badge_class("retry")}>Retry #<%= entry.attempt %></span>
                  </td>
                  <td class="mono"><%= entry.due_at || "n/a" %></td>
                  <td><%= entry.error || "n/a" %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Efficiency Analytics</h2>
              <p class="section-copy">
                Durable runtime events and v1 data-quality status for the metrics catalog.
              </p>
            </div>
            <div class="section-tools">
              <div class="window-selector" role="group" aria-label="Analytics window">
                <button
                  :for={{value, label} <- window_options()}
                  type="button"
                  class={window_button_class(value, @analytics_window)}
                  phx-click="analytics_window"
                  phx-value-window={value}
                ><%= label %></button>
              </div>
              <span class="state-badge">
                <%= format_int(@report.summary.event_sample_count) %> events · <%= window_span_text(@analytics_window, @report) %>
              </span>
            </div>
          </div>

          <%= if @report.summary.event_sample_count == 0 do %>
            <p class="empty-state">No runtime events yet — analytics populates as sessions run.</p>
          <% else %>
            <div class="analytics-grid">
              <article class="analytics-card" :for={panel <- @report.summary.panels}>
                <div class="analytics-card-head">
                  <h3 class="analytics-title"><%= panel.title %></h3>
                  <span class={analytics_status_class(panel.status)} title={analytics_status_title(panel.status)}>
                    <%= analytics_status_label(panel.status) %>
                  </span>
                </div>
                <p class="analytics-question"><%= panel.question %></p>

                <dl class="analytics-metrics">
                  <div :for={metric <- panel.metrics} class="analytics-metric">
                    <dt><%= metric.label %></dt>
                    <dd>
                      <span><%= format_metric_value(metric.value) %></span>
                      <span
                        class={analytics_metric_status_class(metric, panel)}
                        title={analytics_status_title(metric_status(metric, panel))}
                      >
                        <%= analytics_status_label(metric_status(metric, panel)) %>
                      </span>
                    </dd>
                  </div>
                </dl>
              </article>
            </div>
          <% end %>

          <%= if @report.summary.data_quality.gaps != [] do %>
            <ul class="quality-list">
              <li :for={gap <- @report.summary.data_quality.gaps}><%= gap %></li>
            </ul>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">History</h2>
              <p class="section-copy">Daily series from the event log (UTC days).</p>
            </div>
          </div>

          <%= if @report.history.north_star == [] do %>
            <p class="empty-state">No events in this window.</p>
          <% else %>
            <p class="muted history-note">Daily token deltas are not comparable to the live totals card.</p>

            <div class="sparkline-group">
              <.sparkline
                label="Issues first published"
                values={Enum.map(@report.history.north_star, &number_or_nil(&1.cycle.issues_first_published))}
              />
              <.sparkline
                label="Runs completed"
                values={Enum.map(@report.history.north_star, &number_or_nil(&1.cycle.runs_completed))}
              />
              <.sparkline
                label="Rework rate"
                values={Enum.map(@report.history.north_star, &rework_rate_value(&1.rework_rate))}
              />
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 560px;">
                <thead>
                  <tr>
                    <th>Date (UTC)</th>
                    <th>Issues first published</th>
                    <th>Runs completed</th>
                    <th>Rework rate</th>
                    <th>Tokens per issue</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={day <- @report.history.north_star}>
                    <td class="mono"><%= day.date %></td>
                    <td class="numeric"><%= format_metric_value(day.cycle.issues_first_published) %></td>
                    <td class="numeric"><%= format_metric_value(day.cycle.runs_completed) %></td>
                    <td class="numeric"><%= format_metric_value(day.rework_rate) %></td>
                    <td class="numeric"><%= format_metric_value(day.cost_per_issue) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_snapshot(socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:report, AnalyticsCache.report(socket.assigns.analytics_window))
      |> assign(:now, DateTime.utc_now())
      |> assign_page_title()

    if payload[:error] do
      schedule_snapshot_retry(socket)
    else
      reset_snapshot_retry(socket)
    end
  end

  defp assign_page_title(socket) do
    counts = combined_counts(socket.assigns.payload, peer_payloads(socket.assigns.peer_urls, socket.assigns.peers))
    attention = counts.running + counts.blocked
    title = "#{instance_of(socket.assigns.payload).name} · Symphony"
    assign(socket, :page_title, if(attention > 0, do: "(#{attention}) #{title}", else: title))
  end

  defp poll_peers(socket) do
    fetcher = peer_fetcher()

    Enum.reduce(pollable_peer_urls(socket), socket, fn url, acc ->
      start_async(acc, {:peer_fetch, url}, fn -> fetcher.(url) end)
    end)
  end

  defp pollable_peer_urls(socket) do
    if connected?(socket), do: socket.assigns.peer_urls, else: []
  end

  defp peer_fetcher do
    Endpoint.config(:peer_fetcher) || (&PeerStatus.fetch/1)
  end

  defp peer_payloads(peer_urls, peers) do
    Enum.flat_map(peer_urls, fn url ->
      case Map.get(peers, url) do
        {:ok, payload} -> [{peer_name(payload, url), url, payload}]
        _unreachable -> []
      end
    end)
  end

  defp peer_name(payload, url) do
    case payload[:instance] do
      %{name: name} when is_binary(name) -> name
      _missing -> url
    end
  end

  defp instance_of(payload) do
    payload[:instance] || %{name: "unknown", mode: "main", port: nil}
  end

  defp instance_label(%{name: name, port: nil}), do: name
  defp instance_label(%{name: name, port: port}), do: "#{name} · :#{port}"

  defp combined_counts(payload, peer_payloads) do
    [payload | Enum.map(peer_payloads, &elem(&1, 2))]
    |> Enum.map(& &1[:counts])
    |> Enum.reduce(%{running: 0, retrying: 0, blocked: 0}, fn
      %{} = counts, acc ->
        %{
          running: acc.running + (counts[:running] || 0),
          retrying: acc.retrying + (counts[:retrying] || 0),
          blocked: acc.blocked + (counts[:blocked] || 0)
        }

      _missing, acc ->
        acc
    end)
  end

  defp combined_tokens(payload, peer_payloads) do
    [payload | Enum.map(peer_payloads, &elem(&1, 2))]
    |> Enum.map(& &1[:codex_totals])
    |> Enum.reduce(%{total: 0, input: 0, output: 0}, fn
      %{} = totals, acc ->
        %{
          total: acc.total + (totals[:total_tokens] || 0),
          input: acc.input + (totals[:input_tokens] || 0),
          output: acc.output + (totals[:output_tokens] || 0)
        }

      _missing, acc ->
        acc
    end)
  end

  defp combined_runtime_seconds(payload, peer_payloads, now) do
    [payload | Enum.map(peer_payloads, &elem(&1, 2))]
    |> Enum.map(&total_runtime_seconds(&1, now))
    |> Enum.sum()
  end

  defp merged_rows(payload, peer_payloads, key) do
    local = tag_rows(payload[key] || [], instance_of(payload).name, nil)
    peers = Enum.flat_map(peer_payloads, fn {name, url, peer} -> tag_rows(peer[key] || [], name, url) end)
    local ++ peers
  end

  defp tag_rows(rows, instance_name, base_url) do
    Enum.map(rows, &(&1 |> Map.put(:instance_name, instance_name) |> Map.put(:instance_base, base_url)))
  end

  # Peer-owned issues resolve only on their own instance's API.
  defp json_details_href(entry) do
    case entry[:instance_base] do
      nil -> "/api/v1/#{entry.issue_identifier}"
      base -> "#{base}/api/v1/#{entry.issue_identifier}"
    end
  end

  defp since_start_text(false), do: "Since instance start."
  defp since_start_text(true), do: "Combined across reachable instances since each instance start."

  defp window_options, do: [{:h24, "24h"}, {:d7, "7d"}, {:d30, "30d"}, {:all, "All"}]

  defp window_button_class(value, current) when value == current, do: "window-button window-button-active"
  defp window_button_class(_value, _current), do: "window-button"

  defp window_span_text(:h24, _report), do: "last 24h"
  defp window_span_text(:d7, _report), do: "last 7d"
  defp window_span_text(:d30, _report), do: "last 30d"

  # "All history" is meaningless without its actual extent. The span comes
  # from the densified per-day series (the bucketing axis), NOT from
  # window_started_at: that is the first FILE-ORDER event, and backfilled
  # lines appended later can carry older occurred_at dates.
  defp window_span_text(:all, report) do
    case report.history.per_day do
      [] ->
        "all history"

      [first | _rest] = per_day ->
        days = length(per_day)
        "all history · since #{first.date} (#{days} #{if days == 1, do: "day", else: "days"})"
    end
  end

  attr(:card, :map, required: true)

  defp instance_card(assigns) do
    ~H"""
    <article class={["instance-card", !@card.reachable? && "instance-card-unreachable"]}>
      <div class="instance-card-head">
        <span class="instance-name"><%= @card.name %></span>
        <span :if={@card.mode == "maestro"} class="mode-badge">maestro</span>
        <span :if={@card.port} class="muted numeric">:<%= @card.port %></span>
      </div>
      <%= if @card.reachable? do %>
        <p class="instance-card-counts numeric">
          <%= @card.counts.running %> running · <%= @card.counts.retrying %> retrying · <%= @card.counts.blocked %> blocked
        </p>
        <p class="muted numeric instance-card-meta">
          Tokens <%= format_int(@card.tokens_total) %> · Runtime <%= format_runtime_seconds(@card.runtime_seconds) %>
        </p>
      <% else %>
        <p class="muted instance-card-error">unreachable · <%= @card.error %></p>
      <% end %>
    </article>
    """
  end

  defp instance_cards(payload, peer_urls, peers, now) do
    [local_instance_card(payload, now) | Enum.map(peer_urls, &peer_instance_card(&1, Map.get(peers, &1), now))]
  end

  defp local_instance_card(payload, now) do
    payload |> instance_of() |> reachable_card(payload, now)
  end

  defp peer_instance_card(url, {:ok, payload}, now) do
    identity = %{instance_of(payload) | name: peer_name(payload, url)}
    reachable_card(identity, payload, now)
  end

  defp peer_instance_card(url, {:error, reason}, _now) do
    unreachable_card(%{name: url, mode: "main", port: nil}, peer_error_text(reason))
  end

  defp peer_instance_card(url, nil, _now) do
    unreachable_card(%{name: url, mode: "main", port: nil}, "waiting for first poll")
  end

  defp reachable_card(identity, payload, now) do
    case payload[:error] do
      nil ->
        identity
        |> Map.merge(%{
          reachable?: true,
          counts: combined_counts(payload, []),
          tokens_total: combined_tokens(payload, []).total,
          runtime_seconds: total_runtime_seconds(payload, now)
        })

      error ->
        unreachable_card(identity, error[:code] || "error")
    end
  end

  defp unreachable_card(identity, error_text) do
    Map.merge(identity, %{reachable?: false, error: error_text})
  end

  defp peer_error_text(reason) when is_atom(reason), do: to_string(reason)
  defp peer_error_text({:http_status, status}), do: "HTTP #{status}"
  defp peer_error_text(reason), do: inspect(reason)

  attr(:payload, :map, required: true)
  attr(:peer_payloads, :list, required: true)
  attr(:now, :any, required: true)

  defp rate_limit_card(assigns) do
    assigns = assign(assigns, :source, rate_limits_source(assigns.payload, assigns.peer_payloads))

    ~H"""
    <article class="metric-card rate-limit-card">
      <p class="metric-label">Rate limits</p>
      <%= if rate_limit_windows(elem(@source, 1)) == [] and is_nil(rate_limit_credits_text(elem(@source, 1))) do %>
        <p class="metric-detail">No rate-limit snapshot yet.</p>
      <% else %>
        <div class="rate-limit-rows">
          <.rate_limit_window
            :for={{label, bucket} <- rate_limit_windows(elem(@source, 1))}
            label={label}
            bucket={bucket}
            now={@now}
          />
        </div>
        <p :if={rate_limit_credits_text(elem(@source, 1))} class="metric-detail numeric">
          Credits: <%= rate_limit_credits_text(elem(@source, 1)) %>
        </p>
        <p :if={elem(@source, 0)} class="metric-detail">from <%= elem(@source, 0) %></p>
      <% end %>
    </article>
    """
  end

  # Local rate limits win; otherwise the freshest reachable peer's non-empty
  # snapshot (by generated_at) is shown, labeled with that instance's name.
  defp rate_limits_source(payload, peer_payloads) do
    local = payload[:rate_limits]

    if meaningful_rate_limits?(local) do
      {nil, local}
    else
      peer_payloads
      |> Enum.filter(fn {_name, _url, peer} -> meaningful_rate_limits?(peer[:rate_limits]) end)
      |> Enum.max_by(fn {_name, _url, peer} -> generated_at_unix(peer[:generated_at]) end, fn -> nil end)
      |> case do
        nil -> {nil, local}
        {name, _url, peer} -> {name, peer.rate_limits}
      end
    end
  end

  defp meaningful_rate_limits?(rate_limits), do: is_map(rate_limits) and map_size(rate_limits) > 0

  # Freshness ranking must survive malformed peer timestamps: parse-or-zero,
  # never raw string comparison.
  defp generated_at_unix(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      {:error, _reason} -> 0
    end
  end

  defp generated_at_unix(_value), do: 0

  defp schedule_snapshot_retry(socket) do
    if connected?(socket) do
      cancel_snapshot_retry_timer(socket)
      delay = socket.assigns.snapshot_retry_delay_ms || snapshot_retry_initial_ms()
      ref = Process.send_after(self(), :retry_snapshot, delay)

      socket
      |> assign(:snapshot_retry_ref, ref)
      |> assign(:snapshot_retry_delay_ms, min(delay * 2, @snapshot_retry_max_ms))
    else
      socket
    end
  end

  defp reset_snapshot_retry(socket) do
    cancel_snapshot_retry_timer(socket)

    socket
    |> assign(:snapshot_retry_ref, nil)
    |> assign(:snapshot_retry_delay_ms, nil)
  end

  defp cancel_snapshot_retry_timer(%{assigns: %{snapshot_retry_ref: ref}}) when is_reference(ref),
    do: Process.cancel_timer(ref)

  defp cancel_snapshot_retry_timer(_socket), do: :ok

  defp snapshot_retry_initial_ms do
    Endpoint.config(:snapshot_retry_initial_ms) || 5_000
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:payload, :map, required: true)
  attr(:now, :any, required: true)

  defp freshness_indicator(assigns) do
    assigns = assign(assigns, :seconds, seconds_since(assigns.payload[:generated_at], assigns.now))

    ~H"""
    <span :if={@seconds} class={freshness_class(@seconds)}>Updated <%= format_relative_age(@seconds) %></span>
    """
  end

  defp freshness_class(seconds) when is_integer(seconds) and seconds > 300, do: "freshness freshness-dead"
  defp freshness_class(seconds) when is_integer(seconds) and seconds > 60, do: "freshness freshness-stale"
  defp freshness_class(_seconds), do: "freshness"

  defp seconds_since(iso, %DateTime{} = now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, parsed, _offset} -> max(DateTime.diff(now, parsed, :second), 0)
      _ -> nil
    end
  end

  defp seconds_since(_iso, _now), do: nil

  attr(:session_id, :string, default: nil)

  defp copy_session_id(assigns) do
    ~H"""
    <%= if @session_id do %>
      <button
        type="button"
        class="subtle-button"
        data-label="Copy ID"
        data-copy={@session_id}
        onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
      >
        Copy ID
      </button>
    <% else %>
      <span class="muted">n/a</span>
    <% end %>
    """
  end

  attr(:label, :string, required: true)
  attr(:bucket, :any, required: true)
  attr(:now, :any, required: true)

  defp rate_limit_window(assigns) do
    assigns = assign(assigns, :percent, rate_limit_percent(assigns.bucket))

    ~H"""
    <div class="rate-limit-row">
      <div class="rate-limit-head">
        <span class="rate-limit-name"><%= @label %></span>
        <span class="muted numeric"><%= rate_limit_summary(@bucket, @now) %></span>
      </div>
      <div :if={@percent} class="meter">
        <span class={meter_fill_class(@percent)} style={"width: #{@percent}%"}></span>
      </div>
    </div>
    """
  end

  defp rate_limit_windows(rate_limits) when is_map(rate_limits) do
    for {label, keys} <- [{"Primary", ["primary", :primary]}, {"Secondary", ["secondary", :secondary]}],
        bucket = rl_value(rate_limits, keys),
        is_map(bucket),
        do: {label, bucket}
  end

  defp rate_limit_windows(_rate_limits), do: []

  defp rate_limit_percent(bucket) when is_map(bucket) do
    used = rl_value(bucket, ["used_percent", :used_percent, "usedPercent", :usedPercent])
    remaining = rl_value(bucket, ["remaining", :remaining])
    limit = rl_value(bucket, ["limit", :limit])

    cond do
      is_number(used) -> clamp_percent(used)
      is_number(remaining) and is_number(limit) and limit > 0 -> clamp_percent((limit - remaining) / limit * 100)
      true -> nil
    end
  end

  defp rate_limit_percent(_bucket), do: nil

  defp clamp_percent(value), do: value |> max(0) |> min(100) |> Kernel./(1) |> Float.round(1)

  defp meter_fill_class(percent) when percent > 90, do: "meter-fill meter-fill-danger"
  defp meter_fill_class(percent) when percent >= 70, do: "meter-fill meter-fill-warning"
  defp meter_fill_class(_percent), do: "meter-fill"

  defp rate_limit_summary(bucket, now) do
    case Enum.reject([rate_limit_numerals(bucket), rate_limit_reset_text(bucket, now)], &is_nil/1) do
      [] -> "n/a"
      segments -> Enum.join(segments, " · ")
    end
  end

  defp rate_limit_numerals(bucket) do
    remaining = rl_value(bucket, ["remaining", :remaining])
    limit = rl_value(bucket, ["limit", :limit])
    used = rl_value(bucket, ["used_percent", :used_percent, "usedPercent", :usedPercent])

    cond do
      is_number(remaining) and is_number(limit) -> "#{number_text(remaining)}/#{number_text(limit)}"
      is_number(remaining) -> "remaining #{number_text(remaining)}"
      is_number(limit) -> "limit #{number_text(limit)}"
      is_number(used) -> "#{clamp_percent(used)}% used"
      true -> nil
    end
  end

  defp rate_limit_reset_text(bucket, now) do
    reset_in =
      rl_value(bucket, ["reset_in_seconds", :reset_in_seconds, "resetInSeconds", :resetInSeconds])

    reset_at =
      rl_value(bucket, [
        "reset_at",
        :reset_at,
        "resetAt",
        :resetAt,
        "resets_at",
        :resets_at,
        "resetsAt",
        :resetsAt
      ])

    cond do
      is_number(reset_in) -> "resets in #{format_runtime_seconds(reset_in)}"
      seconds = reset_at_delta(reset_at, now) -> "resets in #{format_runtime_seconds(seconds)}"
      true -> nil
    end
  end

  # Real Codex payloads carry resets_at as unix epoch seconds; older shapes may use ISO8601.
  defp reset_at_delta(value, %DateTime{} = now) when is_number(value) do
    case trunc(value) - DateTime.to_unix(now) do
      delta when delta > 0 -> delta
      _ -> nil
    end
  end

  defp reset_at_delta(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> reset_at_delta(DateTime.to_unix(at), now)
      _ -> nil
    end
  end

  defp reset_at_delta(_value, _now), do: nil

  defp rate_limit_credits_text(rate_limits) when is_map(rate_limits) do
    case rl_value(rate_limits, ["credits", :credits]) do
      credits when is_map(credits) ->
        balance = rl_value(credits, ["balance", :balance])

        cond do
          rl_value(credits, ["unlimited", :unlimited]) == true -> "unlimited"
          is_number(balance) -> number_text(balance)
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp rate_limit_credits_text(_rate_limits), do: nil

  defp rl_value(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
  defp rl_value(_map, _keys), do: nil

  defp number_text(value) when is_integer(value), do: format_int(value)
  defp number_text(value) when is_number(value), do: to_string(value)
  defp number_text(_value), do: "n/a"

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  attr(:label, :string, required: true)
  attr(:values, :list, required: true)

  defp sparkline(assigns) do
    values = assigns.values
    numbers = Enum.filter(values, &is_number/1)
    max_value = if numbers == [], do: 0, else: Enum.max(numbers)

    bars =
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {value, index} when is_number(value) ->
          height = if max_value > 0, do: Float.round(max(value, 0) / max_value * 36, 1), else: 0.0
          [%{x: index * 10, y: Float.round(36 - height, 1), height: height}]

        _gap ->
          []
      end)

    assigns = assign(assigns, bars: bars, width: max(length(values), 1) * 10)

    ~H"""
    <figure class="sparkline">
      <figcaption class="sparkline-label"><%= @label %></figcaption>
      <svg viewBox={"0 0 #{@width} 36"} preserveAspectRatio="none" role="img" aria-label={"#{@label} per day"}>
        <rect :for={bar <- @bars} x={bar.x} y={bar.y} width="8" height={bar.height} rx="1"></rect>
      </svg>
    </figure>
    """
  end

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  defp rework_rate_value(value) when is_number(value), do: value

  defp rework_rate_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, rest} when rest in ["", "%"] -> number
      _ -> nil
    end
  end

  defp rework_rate_value(_value), do: nil

  defp format_relative_age(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_age(seconds) when seconds < 48 * 3_600, do: "#{div(seconds, 3_600)}h ago"
  defp format_relative_age(seconds), do: "#{div(seconds, 86_400)}d ago"

  @doc false
  @spec format_runtime_seconds_for_test(number()) :: String.t()
  def format_runtime_seconds_for_test(seconds), do: format_runtime_seconds(seconds)

  @doc false
  @spec rate_limit_summary_for_test(map(), DateTime.t()) :: String.t()
  def rate_limit_summary_for_test(bucket, now), do: rate_limit_summary(bucket, now)

  defp completed_runtime_seconds(payload) do
    case payload[:codex_totals] do
      %{seconds_running: seconds} when is_number(seconds) -> seconds
      _missing -> 0
    end
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload[:running] || [], 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)

    if whole_seconds >= 3_600 do
      "#{div(whole_seconds, 3_600)}h #{whole_seconds |> rem(3_600) |> div(60)}m"
    else
      "#{div(whole_seconds, 60)}m #{rem(whole_seconds, 60)}s"
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp analytics_status_class("direct"), do: "analytics-status analytics-status-direct"
  defp analytics_status_class("partial"), do: "analytics-status analytics-status-partial"
  defp analytics_status_class("gap"), do: "analytics-status analytics-status-gap"
  defp analytics_status_class(_status), do: "analytics-status"

  defp analytics_status_label("direct"), do: "Direct"
  defp analytics_status_label("partial"), do: "Partial"
  defp analytics_status_label("gap"), do: "Gap"
  defp analytics_status_label(status) when is_binary(status), do: status
  defp analytics_status_label(_status), do: "Unknown"

  defp analytics_status_title("direct"), do: "usable as-is"
  defp analytics_status_title("partial"), do: "shown but sample-limited"
  defp analytics_status_title("gap"), do: "data-quality gap only"
  defp analytics_status_title(_status), do: nil

  defp analytics_metric_status_class(metric, panel) do
    metric
    |> metric_status(panel)
    |> analytics_status_class()
    |> Kernel.<>(" analytics-metric-status")
  end

  defp metric_status(%{status: status}, _panel) when is_binary(status), do: status
  defp metric_status(_metric, %{status: status}) when is_binary(status), do: status
  defp metric_status(_metric, _panel), do: "gap"

  defp format_metric_value(value) when is_integer(value), do: format_int(value)
  defp format_metric_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_metric_value(value) when is_binary(value), do: value
  defp format_metric_value(nil), do: "n/a"
  defp format_metric_value(value), do: inspect(value)

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
