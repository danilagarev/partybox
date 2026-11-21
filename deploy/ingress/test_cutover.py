import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_prepare_baza import COMPOSE, NGINX, migration

SOURCE = Path(__file__).resolve().parent
FRONTEND_IMAGE = 'sha256:' + 'a' * 64

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]; state=Path(os.environ['FAKE_STATE'])
with (state/'trace').open('a') as f: f.write(' '.join(args)+'\n')
token=state/'token'
if args[:3]==['container','inspect','caddy']:
    sys.exit(0 if token.exists() or os.environ.get('EXISTING_CADDY') else 1)
if args[:2]==['network','inspect']:
    print(json.dumps([{'Name':n,'IPAM':{'Config':[{'Subnet':'172.20.0.0/16'}]},'Containers':{}} for n in args[2:]]))
elif args[:2]==['image','inspect']:
    print('sha256:'+'b'*64)
elif args[:2]==['inspect','ai-tutor-frontend-prod']:
    if '.Image' in args[-1]: print('sha256:'+'a'*64)
    elif 'project' in args[-1]: print('app')
    else: print('app_internal')
elif args[:2]==['inspect','caddy']:
    print(token.read_text() if token.exists() else 'foreign')
elif args and args[0]=='compose' and 'up' in args:
    marker=state/'up'
    if os.environ.get('FAIL_UP_ONCE') and not marker.exists():
        marker.touch(); sys.exit(1)
    marker.touch()
elif args[:2]==['run','-d']:
    label=args[args.index('--label')+1].split('=',1)[1]
    token.write_text(label)
    if os.environ.get('FAIL_CADDY'): sys.exit(1)
    print('new-caddy')
elif args[:3]==['rm','-f','caddy']:
    token.unlink(missing_ok=True)
'''


class CutoverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pb-cutover-test-')
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.ingress = self.root / 'caddy'
        self.stage = self.ingress / 'staged'
        self.bin = self.root / 'bin'
        for directory in [self.app / 'frontend', self.stage / 'frontend', self.bin]:
            directory.mkdir(parents=True)
        self.files = {
            'frontend/nginx.prod.conf': NGINX,
            'docker-compose.prod.yml': COMPOSE,
            'docker-compose.deploy.yml': 'services:\n  frontend:\n    image: frontend:existing\n',
        }
        for name, content in self.files.items():
            (self.app / name).write_text(content)
        (self.app / '.env.prod').write_text('PLACEHOLDER=true\n')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'core.hooksPath', str(self.app / '.git/hooks'))
        self.git('add', '--', *self.files.keys())
        self.git('commit', '-qm', 'fixture base')
        self.base = self.git('rev-parse', 'HEAD').strip()
        (self.stage / 'base-commit.txt').write_text(self.base + '\n')
        (self.stage / 'source-sha256.json').write_text(json.dumps({
            name: hashlib.sha256(content.encode()).hexdigest() for name, content in self.files.items()
        }))
        (self.stage / 'frontend/nginx.prod.conf').write_text(migration.nginx_http(NGINX, '172.20.0.0/16'))
        (self.stage / 'docker-compose.prod.yml').write_text(migration.compose_proxy(COMPOSE))
        (self.stage / 'Caddyfile').write_text(migration.CADDYFILE)
        shutil.copyfile(SOURCE / 'prepare-baza.py', self.ingress / 'prepare-baza.py')
        (self.bin / 'docker').write_text(FAKE_DOCKER)
        (self.bin / 'curl').write_text('#!/bin/sh\n[ "${FAIL_HEALTH:-0}" != 1 ]\n')
        for path in self.bin.iterdir():
            path.chmod(0o700)

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.app), *args], text=True)

    def switch(self, **extra):
        return subprocess.run(['bash', str(SOURCE / 'switch-to-caddy.sh'), str(self.app), str(self.ingress)],
                              env={**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                                   'FAKE_STATE': str(self.root), 'INGRESS_HEALTH_TIMEOUT': '1', **extra},
                              text=True, capture_output=True)

    def assert_restored(self):
        for name, content in self.files.items():
            self.assertEqual((self.app / name).read_text(), content)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')
        self.assertFalse((self.root / 'token').exists())
        self.assertNotIn(' down ', (self.root / 'trace').read_text())

    def test_success_commits_only_ingress_and_pins_existing_image(self):
        result = self.switch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual(self.git('rev-parse', 'HEAD').strip(), self.base)
        changed = self.git('diff', '--name-only', self.base, 'HEAD').splitlines()
        self.assertEqual(set(changed), {'docker-compose.prod.yml', 'frontend/nginx.prod.conf'})
        backup = Path((self.ingress / 'last-cutover-backup').read_text().strip())
        pin = json.loads((backup / 'frontend-image.json').read_text())
        self.assertEqual(pin['services']['frontend']['image'], FRONTEND_IMAGE)
        trace = (self.root / 'trace').read_text()
        self.assertIn('--no-deps --no-build --pull never', trace)
        self.assertIn('network connect partybox_proxy caddy', trace)
        self.assertNotIn('push', trace)

    def test_frontend_failure_restores_original_configuration(self):
        result = self.switch(FAIL_UP_ONCE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()

    def test_caddy_start_failure_removes_only_owned_container_and_restores(self):
        result = self.switch(FAIL_CADDY='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rm -f caddy', (self.root / 'trace').read_text())
        self.assert_restored()

    def test_certificate_or_health_failure_restores(self):
        result = self.switch(FAIL_HEALTH='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()

    def test_existing_caddy_is_not_replaced(self):
        result = self.switch(EXISTING_CADDY='1')
        self.assertNotEqual(result.returncode, 0)
        trace = (self.root / 'trace').read_text()
        self.assertNotIn('rm -f', trace)
        self.assertNotIn('compose', trace)
        self.assertEqual((self.app / 'frontend/nginx.prod.conf').read_text(), NGINX)

    def test_wrong_user_is_rejected_before_docker_or_files_change(self):
        fake_id = self.bin / 'id'
        fake_id.write_text('#!/bin/sh\nprintf "%s\\n" ' + str(os.getuid() + 1) + '\n')
        fake_id.chmod(0o700)
        result = self.switch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('repository owner', result.stderr)
        self.assertFalse((self.root / 'trace').exists())
        self.assertEqual((self.app / 'frontend/nginx.prod.conf').read_text(), NGINX)

    def test_failed_git_commit_restores_index_and_live_configuration(self):
        hook = self.app / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o700)
        result = self.switch()
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()


if __name__ == '__main__':
    unittest.main()
