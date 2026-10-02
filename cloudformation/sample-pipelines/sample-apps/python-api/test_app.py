from app import app


def test_index_returns_ok():
    client = app.test_client()
    response = client.get("/")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok", "service": "python-api"}


def test_health_returns_healthy():
    client = app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"healthy": True}
