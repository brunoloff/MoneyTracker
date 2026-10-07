"""Loopback HTTPS receiver for the registered Enable Banking redirect."""
import datetime as dt
import ipaddress
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
import connections
import store
import undo


def tls_context(root):
    certificate, private_key = root / 'callback-cert.pem', root / 'callback-key.pem'
    now = dt.datetime.now(dt.timezone.utc)
    renew = True
    if certificate.exists() and private_key.exists():
        try:
            cert = x509.load_pem_x509_certificate(certificate.read_bytes())
            renew = cert.not_valid_after_utc < now + dt.timedelta(days=7)
        except ValueError:
            pass
    if renew:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'MoneyTracker localhost')])
        cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(minutes=5))
                .not_valid_after(now + dt.timedelta(days=365))
                .add_extension(x509.SubjectAlternativeName([
                    x509.DNSName('localhost'), x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
                .sign(key, hashes.SHA256()))
        undo.atomic(private_key, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                  serialization.NoEncryption()))
        undo.atomic(certificate, cert.public_bytes(serialization.Encoding.PEM))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certificate, private_key)
    return context


class CallbackHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Callback URLs contain a single-use authorization code.

    def do_GET(self):
        if self.headers.get('Host') != f'localhost:{self.server.server_port}':
            return self.reply(403, 'Invalid callback host.')
        if urlparse(self.path).path != '/callback':
            return self.reply(404, 'Not found.')
        self.server.app.touch()
        try:
            # The state token authenticates the bank redirect; app cookies are not required.
            connections.complete_callback('https://localhost:8443' + self.path)
        except (ValueError, RuntimeError) as exc:
            return self.reply(400, str(exc))
        except Exception:
            return self.reply(502, 'Could not complete authorization. Return to MoneyTracker and try again.')
        self.send_response(303)
        self.send_header('Location', f'http://localhost:{self.server.app.server_port}/')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def reply(self, status, message):
        from html import escape
        body = (f'<!doctype html><meta name="viewport" content="width=device-width">'
                f'<title>MoneyTracker bank connection</title><h1>Bank connection</h1><p>{escape(message)}</p>'
                f'<p><a href="http://localhost:{self.server.app.server_port}/">Return to MoneyTracker</a></p>').encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'")
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start(app, port=8443):
    context = tls_context(store.PRIVATE)
    server = ThreadingHTTPServer(('127.0.0.1', port), CallbackHandler)
    server.app = app
    try:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    except Exception:
        server.server_close()
        raise
    return server
