# A threaded HTTPS server for the tests' impersonated services. Spliced into their server
# scripts rather than imported (tests/doh-interceptor.nix, the pkarr relay in tests/iroh-ssh.nix).
# Construct `QueuedTlsServer` like `http.server.ThreadingHTTPServer`, then set `.tls` to the
# `ssl.SSLContext` to serve with.
import http.server, ssl, sys, threading, time

# A handshake may not outlive this, so a peer that connects and then says nothing costs one
# thread for a bounded time rather than forever.
HANDSHAKE_TIMEOUT = 30
# Above this a completed handshake is reported anyway. TCG nodes are slow enough that seconds
# are normal, so this is set where "slow" starts to mean "something is queueing".
SLOW_HANDSHAKE = 5

def note(message):
    # stderr, so it reaches the journal and from there the node's console -- i.e. the CI log,
    # which is the only place a stall in here can be seen from.
    print(f"{message} (threads: {threading.active_count()})", file=sys.stderr, flush=True)

# The TLS handshake runs in the per-connection thread, NOT in the accept loop, and that is
# load-bearing rather than tidiness. The obvious spelling -- `ctx.wrap_socket(httpd.socket)`,
# wrapping the LISTENING socket -- makes `ssl.SSLSocket.accept()` negotiate before it returns,
# on a socket that inherits the listener's blocking, timeout-free mode. One peer that opens a
# connection and then stops (a probe that hit its own timeout, a client killed mid-handshake)
# then blocks every connection behind it for as long as it stays open, and once the kernel's
# accept queue fills the symptom at the far end is a `connect()` that SUCCEEDS followed by a
# handshake that never starts. That is not hypothetical: it stalled the aarch64 CI runner for
# over two minutes, failing tests/time-correction.nix, after a clock jump made dnscrypt-proxy
# re-probe all of its upstream entries at once (one per entry in lib/doh-stamps.nix, and a test
# may route all of them here) while another client was mid-connect.
#
# So: nothing that can block runs in the accept loop. The backlog stays generous because a
# burst still has to queue somewhere -- it just drains at accept speed now instead of at
# handshake speed -- and socketserver's default of 5 is short enough to drop SYNs under one.
class QueuedTlsServer(http.server.ThreadingHTTPServer):
    request_queue_size = 128
    tls = None  # the SSLContext, set by the caller

    def process_request_thread(self, request, client_address):
        started = time.monotonic()
        try:
            request.settimeout(HANDSHAKE_TIMEOUT)
            tls = self.tls.wrap_socket(request, server_side=True)
        except OSError as e:
            # `ssl` has already detached and closed the fd; shutdown_request swallows the
            # EBADF that leaves behind, and calling it keeps the bookkeeping in one place.
            note(f"handshake with {client_address} failed after "
                 f"{time.monotonic() - started:.1f}s: {e!r}")
            self.shutdown_request(request)
            return
        elapsed = time.monotonic() - started
        if elapsed > SLOW_HANDSHAKE:
            note(f"handshake with {client_address} took {elapsed:.1f}s")
        # Blocking again for the HTTP conversation, which is what the caller's client expects
        # of a keep-alive connection.
        tls.settimeout(None)
        super().process_request_thread(tls, client_address)

    def handle_error(self, request, client_address):
        # A client walking away mid-request is routine here -- dnscrypt-proxy, for one, re-probes
        # on a timer and drops the connections it no longer needs -- and socketserver's default
        # prints a full traceback for each. One line instead, so the handshake reports above
        # stay findable in a console log. Anything else still gets the traceback.
        e = sys.exc_info()[1]
        if isinstance(e, (ConnectionError, TimeoutError, ssl.SSLError)):
            note(f"{client_address} disconnected: {e!r}")
            return
        super().handle_error(request, client_address)
