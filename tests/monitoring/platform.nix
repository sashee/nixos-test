{ pkgs }:

pkgs.writeText "monitoring-platform.py" ''
  from http.server import BaseHTTPRequestHandler, HTTPServer
  from pathlib import Path

  state_dir = Path("/var/lib/monitoring-platform")
  state_dir.mkdir(parents=True, exist_ok=True)

  class Handler(BaseHTTPRequestHandler):
      def do_POST(self):
          length = int(self.headers.get("Content-Length", "0"))
          body = self.rfile.read(length).decode("utf-8", errors="replace")

          with (state_dir / "events.log").open("a") as events:
              events.write(f"{self.command} {self.path}\n")

          with (state_dir / "bodies.log").open("a") as bodies:
              bodies.write(f"--- {self.command} {self.path} ---\n")
              bodies.write(body)
              bodies.write("\n")

          self.send_response(200)
          self.end_headers()
          self.wfile.write(b"OK")

      def log_message(self, _format, *_args):
          return

  HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
''
