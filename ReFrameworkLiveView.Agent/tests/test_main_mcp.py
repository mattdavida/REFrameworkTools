from backend.main import create_app
from backend.mcp_server import MCP_URL


def test_mcp_is_mounted() -> None:
    application = create_app()
    paths = [getattr(route, "path", "") for route in application.routes]
    assert "/mcp" in paths


def test_health_lists_mcp_url() -> None:
    from fastapi.testclient import TestClient

    with TestClient(create_app()) as client:
        response = client.get("/api/health")
        assert response.status_code == 200
        body = response.json()
        assert body["mcp"] == MCP_URL
        assert body["product"] == "liveview-agent"
