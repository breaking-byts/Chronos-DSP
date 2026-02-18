defmodule ChronosWeb.HealthControllerTest do
  use ChronosWeb.ConnCase, async: false

  setup do
    prev_require_nif = Application.get_env(:chronos, :require_nif, false)
    prev_nif_override = Application.get_env(:chronos, :nif_loaded_override)

    on_exit(fn ->
      Application.put_env(:chronos, :require_nif, prev_require_nif)

      if is_nil(prev_nif_override) do
        Application.delete_env(:chronos, :nif_loaded_override)
      else
        Application.put_env(:chronos, :nif_loaded_override, prev_nif_override)
      end
    end)

    :ok
  end

  test "health endpoint reports ok", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload["status"] == "ok"
    assert payload["ready"] == true
    assert is_boolean(payload["nif_loaded"])
  end

  test "ready endpoint returns 503 when nif is required and unavailable", %{conn: conn} do
    Application.put_env(:chronos, :require_nif, true)
    Application.put_env(:chronos, :nif_loaded_override, false)

    conn = get(conn, "/readyz")
    assert conn.status == 503

    payload = Jason.decode!(conn.resp_body)
    assert payload["status"] == "not_ready"
    assert payload["ready"] == false
    assert payload["require_nif"] == true
  end

  test "ready endpoint returns 200 when nif is required and available", %{conn: conn} do
    Application.put_env(:chronos, :require_nif, true)
    Application.put_env(:chronos, :nif_loaded_override, true)

    conn = get(conn, "/readyz")
    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload["status"] == "ready"
    assert payload["ready"] == true
    assert payload["require_nif"] == true
  end
end
