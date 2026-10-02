"""Tiny Flask app used as a stand-in for a real Python service.

The whole point is to give CodePipeline + CodeBuild something to build.
The test suite next door is what makes the build feel realistic.
"""

from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def index():
    return jsonify(status="ok", service="python-api")


@app.get("/health")
def health():
    return jsonify(healthy=True)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
