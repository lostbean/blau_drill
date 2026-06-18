defmodule BlauDrillWeb.EndpointTest do
  @moduledoc """
  Smoke tests that the endpoint and its configuration load correctly, and that
  no database (Ecto/Repo) configuration leaked into the app — this is an
  explicit non-goal for blau-drill.
  """
  use ExUnit.Case, async: true

  test "endpoint config loads with the expected adapter and pubsub server" do
    config = Application.fetch_env!(:blau_drill, BlauDrillWeb.Endpoint)

    assert config[:adapter] == Bandit.PhoenixAdapter
    assert config[:pubsub_server] == BlauDrill.PubSub

    render_errors = config[:render_errors]
    assert render_errors[:formats][:html] == BlauDrillWeb.ErrorHTML
    assert render_errors[:formats][:json] == BlauDrillWeb.ErrorJSON
  end

  test "a secret_key_base is configured for the test environment" do
    config = Application.fetch_env!(:blau_drill, BlauDrillWeb.Endpoint)
    assert is_binary(config[:secret_key_base])
    assert byte_size(config[:secret_key_base]) >= 64
  end

  test "no Ecto/Repo configuration is present (database is an explicit non-goal)" do
    refute Application.spec(:ecto)
    refute Application.spec(:ecto_sql)
    refute Application.spec(:postgrex)

    # No :ecto_repos configured on the app.
    assert Application.get_env(:blau_drill, :ecto_repos) == nil
  end
end
