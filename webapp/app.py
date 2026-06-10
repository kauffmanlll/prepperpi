#!/usr/bin/env python3
"""
PrepperPi Web Interface
Flask application for system management
"""

from flask import Flask, render_template, jsonify, request
import json
import subprocess
import os
import psutil
from datetime import datetime
from pathlib import Path

app = Flask(__name__)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/status")
def status():
    return render_template("status.html")


@app.route("/settings")
def settings():
    return render_template("settings.html")


@app.route("/api/system/stats")
def system_stats():
    try:
        stats_file = Path("/opt/prepperpi/logs/system_stats.json")
        if stats_file.exists():
            with open(stats_file, "r") as f:
                all_stats = json.load(f)
                return jsonify(all_stats[-1] if all_stats else {})

        return jsonify(
            {
                "cpu_percent": psutil.cpu_percent(),
                "memory": dict(psutil.virtual_memory()._asdict()),
                "disk": dict(psutil.disk_usage("/")._asdict()),
                "timestamp": datetime.now().isoformat(),
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/content/update", methods=["POST"])
def update_content():
    try:
        subprocess.Popen(["/opt/prepperpi/scripts/update_content.sh"])
        return jsonify({"status": "Update started", "success": True})
    except Exception as e:
        return jsonify({"error": str(e), "success": False}), 500


@app.route("/update/start", methods=["POST"])
def update_start():
    try:
        subprocess.check_call(["/bin/systemctl", "start", "prepperpi-update.service"])
        return jsonify({"ok": True, "msg": "Update started"})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.route("/update/log")
def update_log():
    p = "/var/log/prepperpi/update.log"
    if not os.path.exists(p):
        return jsonify({"ok": True, "log": ""})
    with open(p, "r") as f:
        return jsonify({"ok": True, "log": f.read()[-20000:]})


@app.route("/api/system/reboot", methods=["POST"])
def system_reboot():
    try:
        subprocess.Popen(["sudo", "reboot"])
        return jsonify({"status": "Reboot initiated", "success": True})
    except Exception as e:
        return jsonify({"error": str(e), "success": False}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001, debug=False)
