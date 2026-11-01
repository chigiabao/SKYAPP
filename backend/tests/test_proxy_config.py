"""Static privacy policy checks; no app import, database, or proxy process."""
import re
import unittest
from pathlib import Path


TEMPLATE = Path(__file__).resolve().parents[2] / 'deploy' / 'nginx.conf.template'


class ProxyConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = '\n'.join(
            line.split('#', 1)[0] for line in TEMPLATE.read_text(encoding='utf-8').splitlines()
        )

    def test_access_log_is_metrics_only(self):
        formats = re.findall(r'\blog_format\s+(\w+)\s+([^;]+);', self.config)
        self.assertEqual(len(formats), 1)
        name, fields = formats[0]
        self.assertEqual(name, 'privacy_metrics')
        self.assertEqual(
            re.findall(r'\$\w+', fields),
            ['$time_iso8601', '$status', '$body_bytes_sent', '$request_time'],
        )
        self.assertEqual(
            re.findall(r'\baccess_log\s+([^;]+);', self.config),
            ['/var/log/nginx/sky-weather-access.log privacy_metrics'],
        )

    def test_error_logs_cannot_capture_request_targets(self):
        self.assertEqual(
            re.findall(r'\berror_log\s+([^;]+);', self.config),
            ['/dev/null crit'],
        )
        # Keep the standalone config free of inherited/custom logging or modules.
        self.assertNotRegex(self.config, r'\b(include|load_module|mirror|debug_connection)\b')

    def test_listener_requires_explicit_tls_address(self):
        self.assertEqual(
            re.findall(r'\blisten\s+([^;]+);', self.config),
            ['__TLS_LISTEN_ADDRESS__ ssl default_server'],
        )
        self.assertIn('ssl_protocols TLSv1.2 TLSv1.3;', self.config)
        self.assertEqual(
            set(re.findall(r'__[A-Z_]+__', self.config)),
            {'__TLS_LISTEN_ADDRESS__', '__SERVER_NAME__', '__TLS_CERTIFICATE_PATH__',
             '__TLS_PRIVATE_KEY_PATH__'},
        )

    def test_backend_is_loopback_and_forwarded_ip_is_overwritten(self):
        self.assertEqual(
            re.findall(r'\bproxy_pass\s+([^;]+);', self.config),
            ['http://127.0.0.1:8000'],
        )
        self.assertEqual(
            re.findall(r'\bproxy_set_header\s+X-Forwarded-For\s+([^;]+);', self.config),
            ['$remote_addr'],
        )
        self.assertNotIn('$proxy_add_x_forwarded_for', self.config)


if __name__ == '__main__':
    unittest.main()
