#!/usr/bin/env bash
# Offline reverse-proxy acceptance in disposable network, process and mount namespaces.
set -euo pipefail
template=$(realpath "$(dirname "$0")/nginx.conf.in")
exec unshare --net --mount --pid --fork --mount-proc --propagation private bash -s -- "$template" <<'PRIVATE_TEST'
set -euo pipefail
umask 077
mount -t tmpfs -o mode=0755 tmpfs /run
t=/run/orb-canary-proof
mkdir -m 755 "$t"
cd "$t"
ip link set lo up
ip addr add 192.0.2.10/32 dev lo
ip addr add 192.0.2.11/32 dev lo
mkdir -p /run/credentials/orb-native-tests-tls.service /run/orb-native-tests-tls
c=/run/credentials/orb-native-tests-tls.service
chmod 755 /run/credentials
chown nobody:nogroup "$c" /run/orb-native-tests-tls
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=orb-private-test -addext subjectAltName=IP:192.0.2.10 -keyout "$c/worker.key" -out "$c/worker.pem" > /dev/null 2>&1
chown nobody:nogroup "$c/worker.key" "$c/worker.pem"
chmod 400 "$c/worker.key" "$c/worker.pem"
sed 's/@WORKER_MESH_IP@/192.0.2.10/g;s/@CORE_MESH_IP@/192.0.2.11/g' "$1" > nginx.conf
chmod 644 nginx.conf
python3 - > /dev/null 2>&1 <<'PYTHON' &
from http.server import BaseHTTPRequestHandler, HTTPServer

class Fixture(BaseHTTPRequestHandler):
    def reply(self, body):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(b"native-canary-proof")

    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        self.reply(str(len(data)).encode())

HTTPServer(("127.0.0.1", 13088), Fixture).serve_forever()
PYTHON
backend=$!
setpriv --reuid=nobody --regid=nogroup --clear-groups nginx -e stderr -p /run/orb-native-tests-tls -c "$t/nginx.conf" -g 'daemon off;' &
proxy=$!
trap 'kill "$proxy" "$backend" 2>/dev/null || :; wait || :' EXIT
for n in $(seq 1 30); do test -f /run/orb-native-tests-tls/nginx.pid && break; sleep .1; done
curl_cmd=(curl --noproxy '*' -sS --max-time 3 --cacert "$c/worker.pem")
actual=$("${curl_cmd[@]}" --interface 192.0.2.11 https://192.0.2.10:13443/ready)
test "$actual" = native-canary-proof
truncate -s 2M payload
test "$("${curl_cmd[@]}" --interface 192.0.2.11 --data-binary @payload https://192.0.2.10:13443/jobs)" = 2097152
test "$("${curl_cmd[@]}" --interface 127.0.0.1 -o /dev/null -w '%{http_code}' https://192.0.2.10:13443/ready)" = 403
trust_error=0
curl --noproxy '*' -s --interface 192.0.2.11 --max-time 3 https://192.0.2.10:13443/ready >/dev/null || trust_error=$?
test "$trust_error" -eq 60
printf 'Verified TLS, authorized mesh-source read, forbidden alternate source, untrusted certificate refusal.\n'
PRIVATE_TEST
