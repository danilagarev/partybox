import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('prepare_baza', Path(__file__).with_name('prepare-baza.py'))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)

NGINX = '''upstream api { server backend:8000; }
server {
    listen 80;
    server_name sorima.tech;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name sorima.tech;
    ssl_certificate /etc/letsencrypt/live/sorima.tech/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/sorima.tech/privkey.pem;
    root /usr/share/nginx/html;
    add_header Content-Security-Policy "default-src 'self'" always;
    location /api/ {
        proxy_pass http://api;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location ~ "^/([a-z]{8,128})\\.txt$" { proxy_pass http://api; }
    location / { try_files $uri $uri/ /index.html; }
}
'''
COMPOSE = '''services:
  backend:
    image: backend
    networks: [internal]
  frontend:
    image: frontend
    ports:
      - "80:80"
      - "443:443"
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget --no-check-certificate https://localhost:443/ || exit 1"]
  certbot:
    image: certbot
networks:
  internal:
    driver: bridge
'''


class PrepareTests(unittest.TestCase):
    def test_routes_headers_and_regex_are_preserved(self):
        result = migration.nginx_http(NGINX, '172.20.0.0/16')
        self.assertEqual(len(migration.server_blocks(result)), 1)
        for value in ['proxy_pass http://api;', 'X-Real-IP $remote_addr;',
                      'X-Forwarded-Proto https;', "default-src 'self'", 'try_files $uri',
                      'set_real_ip_from 172.20.0.0/16;', 'real_ip_header X-Real-IP;',
                      'listen [::]:80;', '^/([a-z]{8,128})']:
            self.assertIn(value, result)
        for value in ['443 ssl', 'ssl_certificate ', 'return 301 https://', 'http2 on;']:
            self.assertNotIn(value, result)

    def test_unknown_domains_are_rejected(self):
        with self.assertRaises(ValueError):
            migration.nginx_http(NGINX.replace('sorima.tech;', 'other.example;'), '172.20.0.0/16')

    def test_existing_ip_trust_is_rejected(self):
        with self.assertRaises(ValueError):
            migration.nginx_http(NGINX + '\nset_real_ip_from 10.0.0.0/8;\n', '172.20.0.0/16')

    def test_http_upstream_is_not_silently_removed(self):
        value = NGINX.replace('return 301 https://$host$request_uri;', 'proxy_pass http://api;')
        with self.assertRaises(ValueError):
            migration.nginx_http(value, '172.20.0.0/16')

    def test_untrusted_client_ip_forwarding_is_rejected(self):
        value = NGINX.replace('X-Real-IP $remote_addr;', 'X-Real-IP $http_x_real_ip;')
        with self.assertRaises(ValueError):
            migration.nginx_http(value, '172.20.0.0/16')

    def test_composition_changes_only_frontend_and_adds_external_network(self):
        result = migration.compose_proxy(COMPOSE)
        self.assertIn('networks: [internal]', result)
        self.assertIn('aliases: [baza-frontend]', result)
        self.assertIn('external: true', result)
        self.assertIn('http://127.0.0.1:80/health', result)
        self.assertIn('  certbot:\n    image: certbot', result)
        self.assertNotIn('    ports:', result)
        self.assertNotIn('https://localhost:443/', result)

    def test_unknown_ports_and_existing_network_are_rejected(self):
        for value in [COMPOSE.replace('80:80', '8080:80'), COMPOSE + '\n  baza_proxy: {}\n']:
            with self.assertRaises(ValueError):
                migration.compose_proxy(value)


if __name__ == '__main__':
    unittest.main()
