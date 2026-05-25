import os
import json
from flask import Flask, jsonify

app = Flask(__name__)


@app.route("/health")
def health():
    return jsonify({"status": "healthy"})


@app.route("/")
def index():
    return jsonify({
        "service": "sample-app",
        "message": "Platform engineering PoC",
        "environment": {
            "DATABASE_HOST": os.environ.get("DATABASE_HOST", "not set"),
            "DATABASE_PORT": os.environ.get("DATABASE_PORT", "not set"),
            "DATABASE_SECRET": os.environ.get("DATABASE_SECRET", "not set"),
            "CACHE_HOST": os.environ.get("CACHE_HOST", "not set"),
            "CACHE_PORT": os.environ.get("CACHE_PORT", "not set"),
            "EVENTS_TOPIC_ARN": os.environ.get("EVENTS_TOPIC_ARN", "not set"),
            "EVENTS_QUEUE_URL": os.environ.get("EVENTS_QUEUE_URL", "not set"),
        }
    })


@app.route("/db")
def db_check():
    host = os.environ.get("DATABASE_HOST")
    port = os.environ.get("DATABASE_PORT", "5432")
    if not host:
        return jsonify({"error": "DATABASE_HOST not configured"}), 503

    try:
        import psycopg2
        conn = psycopg2.connect(
            host=host, port=port,
            user="postgres", password="platform-generated",
            dbname="postgres", connect_timeout=5
        )
        cur = conn.cursor()
        cur.execute("SELECT version();")
        version = cur.fetchone()[0]
        conn.close()
        return jsonify({"status": "connected", "version": version})
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 503


@app.route("/cache")
def cache_check():
    host = os.environ.get("CACHE_HOST")
    port = os.environ.get("CACHE_PORT", "6379")
    if not host:
        return jsonify({"error": "CACHE_HOST not configured"}), 503

    try:
        import redis
        r = redis.Redis(host=host, port=int(port), socket_connect_timeout=5)
        r.ping()
        return jsonify({"status": "connected", "info": r.info("server")["redis_version"]})
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 503


@app.route("/events/publish")
def events_publish():
    topic_arn = os.environ.get("EVENTS_TOPIC_ARN")
    if not topic_arn:
        return jsonify({"error": "EVENTS_TOPIC_ARN not configured"}), 503

    try:
        import boto3
        sns = boto3.client("sns", region_name=os.environ.get("AWS_REGION", "us-east-1"))
        response = sns.publish(
            TopicArn=topic_arn,
            Message=json.dumps({"event": "test", "source": "sample-app"}),
            Subject="platform-test"
        )
        return jsonify({"status": "published", "messageId": response["MessageId"]})
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
