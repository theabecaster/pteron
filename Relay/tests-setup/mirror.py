"""A stand-in for the release download site, for Relay/test-install.sh.

    python3 -I mirror.py <folder to serve> <file to write the port to> <file to log requests to>

Serves the folder on 127.0.0.1 at a free port and appends the path of every request to the log.
A file `.delay` in the folder holds a number of seconds to wait before answering a request for
a release file (a path with `helper-v`), so a test can stop a download half way.
"""

import http.server
import os
import sys
import time

root, port_file, log_file = sys.argv[1:4]


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def do_GET(self):
        with open(log_file, "a") as log:
            log.write(self.path + "\n")
        delay = os.path.join(root, ".delay")
        if "helper-v" in self.path and os.path.exists(delay):
            with open(delay) as f:
                time.sleep(float(f.read().strip() or 0))
        super().do_GET()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
# A test that stops a download closes its connection early. That is expected, so say nothing.
server.handle_error = lambda request, client_address: None
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
