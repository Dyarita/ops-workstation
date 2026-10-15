#!/usr/bin/env python3
"""Local fleet panel. Listens on 127.0.0.1 only."""
import html
import os
import shutil
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8765
TASKS = ("web", "markets", "prices", "social")
ROOT = Path(os.environ.get("OPS_WORKSTATION_ROOT", Path(__file__).resolve().parents[1]))
INVENTORY = Path(os.environ.get("OPS_FLEET_FILE", Path.home() / ".config" / "ops-workstation" / "fleet.tsv"))


def load_rows():
    if not INVENTORY.exists():
        return []
    rows = []
    for line in INVENTORY.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        name, ssh, task = parts[0], parts[1], parts[2]
        port = parts[3] if len(parts) > 3 and parts[3] else str(19000 + (abs(hash(name)) % 1000))
        rows.append({"name": name, "ssh": ssh, "task": task, "port": port})
    return rows


def save_rows(rows):
    INVENTORY.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# name\tssh\ttask\tlocal_port"]
    for row in rows:
        lines.append(f"{row['name']}\t{row['ssh']}\t{row['task']}\t{row['port']}")
    INVENTORY.write_text("\n".join(lines) + "\n")


def page(body, title="Flota"):
    return f"""<!doctype html>
<meta charset="utf-8">
<title>{html.escape(title)}</title>
<style>
  body {{ font: 15px/1.45 ui-sans-serif, system-ui, sans-serif; margin: 2rem auto; max-width: 52rem; color: #e7ecf3; background: #0b1220; }}
  a {{ color: #79c0ff; }}
  table {{ width: 100%; border-collapse: collapse; }}
  th, td {{ text-align: left; padding: .45rem .3rem; border-bottom: 1px solid #243044; }}
  form.inline {{ display: inline; }}
  button, input, select {{ font: inherit; }}
  button {{ background: #16324f; color: #e7ecf3; border: 1px solid #3d5a80; border-radius: 6px; padding: .25rem .6rem; }}
  .muted {{ color: #8b9bb4; }}
  pre {{ white-space: pre-wrap; background: #101826; padding: .8rem; border-radius: 8px; }}
</style>
<h1>Flota OpenClaw</h1>
<p class="muted">Cada VM hace una tarea. Este panel las instala y abre su gateway. La GUI no vive dentro de la VM.</p>
{body}
"""


def shell(args, timeout=30, stdin=""):
    try:
        done = subprocess.run(args, input=stdin, text=True, capture_output=True, timeout=timeout)
        return done.returncode, (done.stdout or "") + (done.stderr or "")
    except subprocess.TimeoutExpired as exc:
        return 124, (exc.stdout or "") + (exc.stderr or "") + "\ntimeout"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def send_html(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            self.send_html(200, page(self.render_home()))
            return
        self.send_html(404, page("<p>No está.</p>"))

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode())
        path = urllib.parse.urlparse(self.path).path
        if path == "/add":
            self.add(form)
        elif path == "/assign":
            self.assign(form)
        elif path == "/apply":
            self.apply(form)
        elif path == "/open":
            self.open_vm(form)
        else:
            self.send_html(404, page("<p>No está.</p>"))

    def render_home(self):
        rows = load_rows()
        options = "".join(f"<option>{html.escape(task)}</option>" for task in TASKS)
        body = [
            "<table><tr><th>VM</th><th>SSH</th><th>Tarea</th><th></th></tr>"
        ]
        if not rows:
            body.append("<tr><td colspan=4 class=muted>Todavía no hay VMs.</td></tr>")
        for row in rows:
            name = html.escape(row["name"])
            body.append(
                "<tr>"
                f"<td>{name}</td>"
                f"<td><code>{html.escape(row['ssh'])}</code></td>"
                f"<td>{html.escape(row['task'])}</td>"
                "<td>"
                f"<form class=inline method=post action=/open><input type=hidden name=name value='{name}'><button>Abrir</button></form> "
                f"<form class=inline method=post action=/apply><input type=hidden name=name value='{name}'><button>Instalar</button></form> "
                f"<form class=inline method=post action=/assign><input type=hidden name=name value='{name}'>"
                f"<select name=task>{options}</select><button>Asignar</button></form>"
                "</td></tr>"
            )
        body.append("</table>")
        body.append(
            "<h2>Agregar VM</h2>"
            "<form method=post action=/add>"
            "<p><input name=name placeholder=nombre required> "
            "<input name=ssh placeholder=user@ip required size=28> "
            f"<select name=task>{options}</select> "
            "<button>Agregar</button></p></form>"
            "<p class=muted>Instalar clona el repo en la VM y corre "
            "<code>sudo ./install-openclaw --headless --task …</code>. "
            "Hace falta SSH con llave, sin password.</p>"
        )
        return "\n".join(body)

    def add(self, form):
        name = (form.get("name") or [""])[0].strip()
        ssh = (form.get("ssh") or [""])[0].strip()
        task = (form.get("task") or ["web"])[0].strip()
        if not name or not ssh or task not in TASKS:
            self.send_html(400, page("<p>Falta el nombre, el SSH o la tarea.</p><p><a href=/>Volver</a></p>"))
            return
        rows = [row for row in load_rows() if row["name"] != name]
        port = str(19010 + len(rows))
        rows.append({"name": name, "ssh": ssh, "task": task, "port": port})
        save_rows(rows)
        self.redirect()

    def assign(self, form):
        name = (form.get("name") or [""])[0].strip()
        task = (form.get("task") or [""])[0].strip()
        rows = load_rows()
        found = False
        for row in rows:
            if row["name"] == name and task in TASKS:
                row["task"] = task
                found = True
        if not found:
            self.send_html(404, page("<p>VM no encontrada.</p>"))
            return
        save_rows(rows)
        row = next(item for item in rows if item["name"] == name)
        src = ROOT / "fleet" / "tasks" / f"{task}.md"
        if src.exists() and shutil.which("ssh"):
            marker = "OPS_TASK_EOF"
            remote = (
                "mkdir -p ~/.openclaw/workspace\n"
                f"cat > ~/.openclaw/workspace/TASK.md <<'{marker}'\n"
                f"{src.read_text()}\n{marker}\n"
                f"printf '%s\\n' {task} > ~/.openclaw/workspace/TASK_NAME\n"
            )
            code, out = shell(["ssh", "-o", "BatchMode=yes", row["ssh"], "bash -s"], timeout=30, stdin=remote)
            if code != 0:
                self.send_html(200, page(
                    f"<p>Tarea guardada en este equipo. La VM no la recibió.</p><pre>{html.escape(out)}</pre><p><a href=/>Volver</a></p>"
                ))
                return
        self.redirect()

    def apply(self, form):
        name = (form.get("name") or [""])[0].strip()
        row = next((item for item in load_rows() if item["name"] == name), None)
        if row is None:
            self.send_html(404, page("<p>VM no encontrada.</p>"))
            return
        task = row["task"]
        script = (
            "set -euo pipefail\n"
            "if [ ! -d \"$HOME/ops-workstation/.git\" ]; then\n"
            "  git clone https://github.com/Dyarita/ops-workstation.git \"$HOME/ops-workstation\"\n"
            "fi\n"
            "cd \"$HOME/ops-workstation\"\n"
            "git pull --ff-only\n"
            f"sudo -n ./install-openclaw --headless --task {task}\n"
        )
        code, out = shell(["ssh", "-o", "BatchMode=yes", row["ssh"], "bash -s"], timeout=900, stdin=script)
        self.send_html(
            200,
            page(
                f"<h2>{html.escape(name)}</h2><p>exit {code}</p><pre>{html.escape(out[-8000:])}</pre><p><a href=/>Volver</a></p>"
            ),
        )

    def open_vm(self, form):
        name = (form.get("name") or [""])[0].strip()
        row = next((item for item in load_rows() if item["name"] == name), None)
        if row is None:
            self.send_html(404, page("<p>VM no encontrada.</p>"))
            return
        port = row["port"]
        shell(
            [
                "ssh", "-f", "-N",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "BatchMode=yes",
                "-L", f"{port}:127.0.0.1:18789",
                row["ssh"],
            ],
            timeout=20,
        )
        url = f"http://127.0.0.1:{port}/"
        opener = shutil.which("xdg-open")
        if opener:
            subprocess.Popen([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.send_html(200, page(f"<p>Gateway de {html.escape(name)}: <a href='{url}'>{url}</a></p><p><a href=/>Volver</a></p>"))

    def redirect(self):
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    if args.open:
        opener = shutil.which("xdg-open")
        if opener:
            subprocess.Popen([opener, f"http://{HOST}:{PORT}/"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"fleet panel http://{HOST}:{PORT}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
