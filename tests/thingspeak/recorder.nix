{ pkgs }:

# A stand-in for api.thingspeak.com: records every request line and answers whatever the test
# tells it to. Two files drive it, both optional, so the default is the success case:
#
#   response  the body to return, verbatim ("1" if absent). "0" is how ThingSpeak rejects an
#             update under HTTP 200, which is the case a status check alone cannot see.
#   status    the HTTP status to return ("200" if absent).
#
# Plain HTTP, not HTTPS, because the endpoint is an option (common.thingspeak.updateUrl). The
# alternative -- keeping the real hostname and intercepting DNS plus TLS for it, the way
# tests/doh-interceptor.nix has to -- would be a lot of machinery to prove something about
# query-string assembly.
pkgs.writeText "thingspeak-recorder.py" ''
  from http.server import BaseHTTPRequestHandler, HTTPServer
  from pathlib import Path

  state_dir = Path("/var/lib/thingspeak-recorder")
  state_dir.mkdir(parents=True, exist_ok=True)

  def control(name, fallback):
      try:
          return (state_dir / name).read_text().strip()
      except OSError:
          return fallback

  class Handler(BaseHTTPRequestHandler):
      def _record_and_answer(self):
          length = int(self.headers.get("Content-Length", "0"))
          self.rfile.read(length)

          # The whole request line, query string included: everything worth asserting on --
          # created_at, which fields were sent and under which numbers, and that the api_key
          # is there at all -- is in the query string, because that is where the spec puts it.
          with (state_dir / "requests.log").open("a") as requests:
              requests.write(f"{self.command} {self.path}\n")

          body = control("response", "1").encode()
          self.send_response(int(control("status", "200")))
          self.send_header("Content-Length", str(len(body)))
          self.end_headers()
          self.wfile.write(body)

      def do_POST(self):
          self._record_and_answer()

      def do_GET(self):
          # Readiness only, and deliberately not recorded: the test polls this to know the
          # server is up, and those polls must not show up as reports.
          if self.path == "/healthz":
              self.send_response(200)
              self.send_header("Content-Length", "2")
              self.end_headers()
              self.wfile.write(b"ok")
              return
          self._record_and_answer()

      def log_message(self, _format, *_args):
          return

  HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
''
