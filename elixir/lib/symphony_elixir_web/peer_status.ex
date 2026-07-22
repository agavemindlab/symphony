defmodule SymphonyElixirWeb.PeerStatus do
  @moduledoc """
  Fetches and normalizes `/api/v1/state` from a peer Symphony instance.

  Req decodes JSON into string-keyed maps while the dashboard templates use
  atom access, so every field the dashboard renders is mapped through an
  explicit whitelist into the `SymphonyElixirWeb.Presenter` atom-keyed
  shapes. Unknown keys are dropped; missing fields become nils. Arbitrary
  keys are never converted to atoms. `rate_limits` stays as-is — the
  rate-limit helpers already handle string keys.
  """

  @receive_timeout_ms 1_500

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(base_url) when is_binary(base_url) do
    (String.trim_trailing(base_url, "/") <> "/api/v1/state")
    |> Req.get(retry: false, redirect: false, receive_timeout: @receive_timeout_ms)
    |> handle_response()
  end

  @doc false
  @spec handle_response({:ok, Req.Response.t()} | {:error, Exception.t()}) :: {:ok, map()} | {:error, term()}
  def handle_response({:ok, %Req.Response{status: 200, body: body}}) when is_map(body), do: {:ok, normalize(body)}
  def handle_response({:ok, %Req.Response{status: 200}}), do: {:error, :invalid_payload}
  def handle_response({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}
  def handle_response({:error, %{reason: reason}}) when is_atom(reason), do: {:error, reason}
  def handle_response({:error, exception}), do: {:error, exception}

  @doc false
  @spec normalize(map()) :: map()
  def normalize(body) when is_map(body) do
    %{
      generated_at: string_or_nil(body["generated_at"]),
      error: normalize_error(body["error"]),
      instance: normalize_instance(body["instance"]),
      counts: normalize_counts(body["counts"]),
      running: normalize_entries(body["running"], &normalize_running_entry/1),
      retrying: normalize_entries(body["retrying"], &normalize_retry_entry/1),
      blocked: normalize_entries(body["blocked"], &normalize_blocked_entry/1),
      codex_totals: normalize_codex_totals(body["codex_totals"]),
      rate_limits: if(is_map(body["rate_limits"]), do: body["rate_limits"])
    }
  end

  defp normalize_error(%{} = error) do
    %{code: string_or_nil(error["code"]), message: string_or_nil(error["message"])}
  end

  defp normalize_error(_error), do: nil

  defp normalize_instance(%{} = instance) do
    %{
      name: string_or_nil(instance["name"]),
      mode: string_or_nil(instance["mode"]),
      port: int_or_nil(instance["port"])
    }
  end

  defp normalize_instance(_instance), do: nil

  defp normalize_counts(%{} = counts) do
    %{
      running: int_or_nil(counts["running"]),
      retrying: int_or_nil(counts["retrying"]),
      blocked: int_or_nil(counts["blocked"])
    }
  end

  defp normalize_counts(_counts), do: nil

  defp normalize_entries(entries, normalizer) when is_list(entries) do
    entries |> Enum.filter(&is_map/1) |> Enum.map(normalizer)
  end

  defp normalize_entries(_entries, _normalizer), do: []

  defp normalize_running_entry(entry) do
    %{
      issue_id: string_or_nil(entry["issue_id"]),
      issue_identifier: string_or_nil(entry["issue_identifier"]),
      issue_title: string_or_nil(entry["issue_title"]),
      issue_url: string_or_nil(entry["issue_url"]),
      state: string_or_nil(entry["state"]),
      session_id: string_or_nil(entry["session_id"]),
      turn_count: int_or_nil(entry["turn_count"]) || 0,
      last_event: string_or_nil(entry["last_event"]),
      last_message: string_or_nil(entry["last_message"]),
      started_at: string_or_nil(entry["started_at"]),
      last_event_at: string_or_nil(entry["last_event_at"]),
      tokens: normalize_tokens(entry["tokens"])
    }
  end

  defp normalize_retry_entry(entry) do
    %{
      issue_id: string_or_nil(entry["issue_id"]),
      issue_identifier: string_or_nil(entry["issue_identifier"]),
      issue_title: string_or_nil(entry["issue_title"]),
      issue_url: string_or_nil(entry["issue_url"]),
      attempt: int_or_nil(entry["attempt"]),
      due_at: string_or_nil(entry["due_at"]),
      error: string_or_nil(entry["error"])
    }
  end

  defp normalize_blocked_entry(entry) do
    %{
      issue_id: string_or_nil(entry["issue_id"]),
      issue_identifier: string_or_nil(entry["issue_identifier"]),
      issue_title: string_or_nil(entry["issue_title"]),
      issue_url: string_or_nil(entry["issue_url"]),
      state: string_or_nil(entry["state"]),
      error: string_or_nil(entry["error"]),
      session_id: string_or_nil(entry["session_id"]),
      blocked_at: string_or_nil(entry["blocked_at"]),
      last_event: string_or_nil(entry["last_event"]),
      last_message: string_or_nil(entry["last_message"]),
      last_event_at: string_or_nil(entry["last_event_at"])
    }
  end

  defp normalize_tokens(%{} = tokens) do
    %{
      input_tokens: int_or_nil(tokens["input_tokens"]),
      output_tokens: int_or_nil(tokens["output_tokens"]),
      total_tokens: int_or_nil(tokens["total_tokens"])
    }
  end

  defp normalize_tokens(_tokens), do: %{input_tokens: nil, output_tokens: nil, total_tokens: nil}

  defp normalize_codex_totals(%{} = totals) do
    %{
      input_tokens: number_or_nil(totals["input_tokens"]),
      output_tokens: number_or_nil(totals["output_tokens"]),
      total_tokens: number_or_nil(totals["total_tokens"]),
      cached_input_tokens: number_or_nil(totals["cached_input_tokens"]),
      reasoning_output_tokens: number_or_nil(totals["reasoning_output_tokens"]),
      seconds_running: number_or_nil(totals["seconds_running"])
    }
  end

  defp normalize_codex_totals(_totals), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_value), do: nil

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil
end
