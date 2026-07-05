defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @snapshot_retry_max_ms 30_000

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
      |> load_snapshot()

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
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
  def render(assigns) do
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
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card rate-limit-card">
            <p class="metric-label">Rate limits</p>
            <%= if rate_limit_windows(@payload.rate_limits) == [] and is_nil(rate_limit_credits_text(@payload.rate_limits)) do %>
              <p class="metric-detail">No rate-limit snapshot yet.</p>
            <% else %>
              <div class="rate-limit-rows">
                <.rate_limit_window
                  :for={{label, bucket} <- rate_limit_windows(@payload.rate_limits)}
                  label={label}
                  bucket={bucket}
                  now={@now}
                />
              </div>
              <p :if={rate_limit_credits_text(@payload.rate_limits)} class="metric-detail numeric">
                Credits: <%= rate_limit_credits_text(@payload.rate_limits) %>
              </p>
            <% end %>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
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

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class={blocked_section_title_class(@payload.counts.blocked)}>Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
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
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class("retry")}>Retry #<%= entry.attempt %></span>
                    </td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Efficiency Analytics</h2>
              <p class="section-copy">
                Durable runtime events and v1 data-quality status for the metrics catalog.
              </p>
            </div>
            <span class="state-badge">
              <%= format_int(analytics_payload(@payload).event_sample_count) %> events<%= if analytics_window_text(@payload) do %><span class="analytics-window">&nbsp;· <%= analytics_window_text(@payload) %></span><% end %>
            </span>
          </div>

          <%= if analytics_payload(@payload).event_sample_count == 0 do %>
            <p class="empty-state">No runtime events yet — analytics populates as sessions run.</p>
          <% else %>
            <div class="analytics-grid">
              <article class="analytics-card" :for={panel <- analytics_panels(@payload)}>
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

          <%= if analytics_gaps(@payload) != [] do %>
            <ul class="quality-list">
              <li :for={gap <- analytics_gaps(@payload)}><%= gap %></li>
            </ul>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">History (rollup)</h2>
              <p class="section-copy">North-star history series from mix symphony.analytics.rollup.</p>
              <p class="section-copy">Daily deltas from rollup; not comparable to the live totals card.</p>
            </div>
          </div>

          <%= if @payload[:rollup] do %>
            <p class="muted rollup-meta">
              <span class={rollup_age_class(@payload.rollup, @now)}>
                generated <%= rollup_generated_text(@payload.rollup, @now) %>
              </span>
              · covers <span class="numeric"><%= @payload.rollup.days %></span> days · table shows the last 14.
            </p>

            <div class="sparkline-group">
              <.sparkline
                label="Issues first published"
                values={Enum.map(@payload.rollup.last_14_north_star, &number_or_nil(&1.cycle.issues_first_published))}
              />
              <.sparkline
                label="Runs completed"
                values={Enum.map(@payload.rollup.last_14_north_star, &number_or_nil(&1.cycle.runs_completed))}
              />
              <.sparkline
                label="Rework rate"
                values={Enum.map(@payload.rollup.last_14_north_star, &rework_rate_value(&1.rework_rate))}
              />
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 560px;">
                <thead>
                  <tr>
                    <th>Date</th>
                    <th>Issues first published</th>
                    <th>Runs completed</th>
                    <th>Rework rate</th>
                    <th>Tokens per issue</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={day <- @payload.rollup.last_14_north_star}>
                    <td class="mono"><%= day.date %></td>
                    <td class="numeric"><%= format_metric_value(day.cycle.issues_first_published) %></td>
                    <td class="numeric"><%= format_metric_value(day.cycle.runs_completed) %></td>
                    <td class="numeric"><%= format_metric_value(day.rework_rate) %></td>
                    <td class="numeric"><%= format_metric_value(day.cost_per_issue) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% else %>
            <p class="empty-state">No rollup yet — run: mix symphony.analytics.rollup</p>
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
      |> assign(:now, DateTime.utc_now())

    if payload[:error] do
      schedule_snapshot_retry(socket)
    else
      reset_snapshot_retry(socket)
    end
  end

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
    with credits when is_map(credits) <- rl_value(rate_limits, ["credits", :credits]) do
      balance = rl_value(credits, ["balance", :balance])

      cond do
        rl_value(credits, ["unlimited", :unlimited]) == true -> "unlimited"
        is_number(balance) -> number_text(balance)
        true -> nil
      end
    else
      _ -> nil
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

  defp rollup_age_class(rollup, now) do
    case seconds_since(rollup.generated_at, now) do
      seconds when is_integer(seconds) and seconds > 86_400 -> "rollup-age rollup-age-stale"
      _ -> "rollup-age"
    end
  end

  defp rollup_generated_text(rollup, now) do
    case seconds_since(rollup.generated_at, now) do
      nil -> to_string(rollup.generated_at)
      seconds -> format_relative_age(seconds)
    end
  end

  defp format_relative_age(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_age(seconds) when seconds < 48 * 3_600, do: "#{div(seconds, 3_600)}h ago"
  defp format_relative_age(seconds), do: "#{div(seconds, 86_400)}d ago"

  @doc false
  def format_runtime_seconds_for_test(seconds), do: format_runtime_seconds(seconds)

  @doc false
  def rate_limit_summary_for_test(bucket, now), do: rate_limit_summary(bucket, now)

  defp blocked_section_title_class(count) when is_integer(count) and count > 0,
    do: "section-title section-title-danger"

  defp blocked_section_title_class(_count), do: "section-title"

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
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

  defp analytics_payload(%{analytics: %{} = analytics}), do: analytics
  defp analytics_payload(_payload), do: %{event_sample_count: 0, panels: [], data_quality: %{gaps: []}}

  defp analytics_panels(payload) do
    payload
    |> analytics_payload()
    |> Map.get(:panels, [])
  end

  defp analytics_gaps(payload) do
    payload
    |> analytics_payload()
    |> Map.get(:data_quality, %{})
    |> Map.get(:gaps, [])
  end

  defp analytics_window_text(payload) do
    analytics = analytics_payload(payload)

    with started when is_binary(started) <- Map.get(analytics, :window_started_at),
         ended when is_binary(ended) <- Map.get(analytics, :window_ended_at),
         {:ok, started_at, _} <- DateTime.from_iso8601(started),
         {:ok, ended_at, _} <- DateTime.from_iso8601(ended) do
      "~#{format_window_duration(max(DateTime.diff(ended_at, started_at, :second), 0))} window"
    else
      _ -> nil
    end
  end

  defp format_window_duration(seconds) when seconds < 3_600, do: "#{round(seconds / 60)}m"
  defp format_window_duration(seconds) when seconds < 48 * 3_600, do: "#{round(seconds / 3_600)}h"
  defp format_window_duration(seconds), do: "#{round(seconds / 86_400)}d"

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
