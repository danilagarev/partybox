#!/usr/bin/env python3
"""Stage a Baza -> standalone Caddy migration; never apply it or restart services."""
import argparse
import difflib
import hashlib
import ipaddress
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def replace_once(pattern, replacement, text, flags=0):
    result, count = re.subn(pattern, replacement, text, flags=flags)
    require(count == 1, 'Неоднозначный формат конфигурации: ' + pattern)
    return result


def server_blocks(text):
    result = []
    for match in re.finditer(r'(?m)^[ \t]*server\s*\{', text):
        depth, quote, escaped, comment = 0, None, False, False
        for pos in range(text.index('{', match.start()), len(text)):
            char = text[pos]
            if comment:
                comment = char != '\n'
            elif escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif quote:
                if char == quote:
                    quote = None
            elif char in "\"'":
                quote = char
            elif char == '#':
                comment = True
            elif char == '{':
                depth += 1
            elif char == '}':
                depth -= 1
                if depth == 0:
                    result.append((match.start(), pos + 1, text[match.start():pos + 1]))
                    break
        else:
            raise ValueError('Незакрытый server block')
    return result


def nginx_http(text, subnet):
    ipaddress.ip_network(subnet)
    blocks = server_blocks(text)
    require(len(blocks) == 2, 'Ожидались ровно два server block; требуется ручное ревью')
    require(not re.search(r'(?m)^\s*(set_real_ip_from|real_ip_header|real_ip_recursive)\b', text),
            'Уже есть real_ip настройки; требуется ручное ревью')
    tls, plain = None, None
    for start, end, body in blocks:
        names = re.findall(r'(?m)^\s*server_name\s+([^;]+);', body)
        require(names == ['sorima.tech'], 'Неожиданный server_name; другие домены не меняются автоматически')
        if re.search(r'\blisten\s+[^;]*443\s+ssl\b', body):
            require(tls is None, 'Несколько TLS server block')
            tls = (start, end, body)
        else:
            require(plain is None, 'Несколько HTTP server block')
            require(re.search(r'\breturn\s+30[18]\s+https://', body), 'HTTP block не является redirect')
            require(not re.search(r'\b(proxy_pass|fastcgi_pass|uwsgi_pass)\b', body),
                    'В HTTP block есть upstream; требуется ручное ревью')
            plain = (start, end, body)
    require(tls and plain, 'Не найдены ожидаемые HTTP redirect и TLS server')
    body = tls[2]
    body = re.sub(r'(?m)^[ \t]*listen\s+[^;]+;[^\n]*\n?', '', body)
    body = re.sub(r'(?m)^[ \t]*(?:ssl_[a-z_]+|http2)\s+[^;]*;[^\n]*\n?', '', body)
    require(not re.search(r'(?m)^\s*(?:ssl\b|ssl_|listen\b|http2\b)', body),
            'Остались неподдержанные TLS/listen директивы')
    body = body.replace('{', '{\n    listen 80;\n    listen [::]:80;', 1)
    realip = ('    # Only Caddy and this frontend belong to baza_proxy.\n'
              f'    set_real_ip_from {subnet};\n'
              '    real_ip_header X-Real-IP;\n    real_ip_recursive off;\n')
    body = replace_once(r'(?m)^([ \t]*server_name\s+sorima\.tech;[^\n]*\n)',
                        lambda m: m[0] + realip, body)
    body, count = re.subn(r'(proxy_set_header\s+X-Forwarded-Proto\s+)\$scheme;', r'\1https;', body)
    require(count > 0, 'Не найден X-Forwarded-Proto $scheme')
    ips = re.findall(r'proxy_set_header\s+X-Real-IP\s+([^;]+);', body)
    require(ips and all(value.strip() == '$remote_addr' for value in ips),
            'Неподдерживаемая передача X-Real-IP; требуется ручное ревью')
    require(all(value.strip() == 'https' for value in
                re.findall(r'proxy_set_header\s+X-Forwarded-Proto\s+([^;]+);', body)),
            'Остались неподдерживаемые X-Forwarded-Proto')
    require(not re.search(r'\breturn\s+30[18]\s+https://', body), 'В новом server остался HTTPS redirect')
    for start, end, _ in sorted(blocks, reverse=True):
        text = text[:start] + (body if start == tls[0] else '') + text[end:]
    return '# Generated for Caddy TLS termination; preserve this change in Baza Git.\n' + text


def compose_proxy(text):
    match = re.search(r'(?ms)^  frontend:\n.*?(?=^  [a-zA-Z0-9_-]+:|^networks:|\Z)', text)
    require(match is not None, 'Не найден frontend service')
    block = match[0]
    ports = re.search(r'(?m)^    ports:\n((?:[ \t]+-\s+[^\n]+\n)+)', block)
    require(ports is not None, 'Не найдены frontend ports')
    entries = [s.strip().lstrip('-').strip().strip('\"\'') for s in ports[1].splitlines()]
    require(set(entries) == {'80:80', '443:443'} and len(entries) == 2,
            'Неожиданные frontend ports; требуется ручное ревью')
    block = block[:ports.start()] + block[ports.end():]
    block = replace_once(r'(?m)^    networks:\n      - internal\n',
                         '    networks:\n      internal: {}\n      baza_proxy:\n        aliases: [baza-frontend]\n', block)
    block = replace_once(r'https://localhost:443/', 'http://127.0.0.1:80/health', block)
    block = block.replace('--no-check-certificate ', '')
    text = text[:match.start()] + block + text[match.end():]
    require(not re.search(r'(?m)^  baza_proxy:', text), 'baza_proxy уже объявлена')
    return replace_once(r'(?m)^networks:\n',
                        'networks:\n  baza_proxy:\n    external: true\n    name: baza_proxy\n', text)


CADDYFILE = '''sorima.tech {
    reverse_proxy baza-frontend:80 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
    }
}

partybox.sorima.tech {
    reverse_proxy partybox-api:3000 {
        header_up X-Forwarded-For {remote_host}
    }
}
'''


def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    # Only callers explicitly print non-sensitive results; never print full Compose output.
    require(result.returncode == 0, 'Команда проверки не прошла: ' + args[0] + ' (рабочие файлы не изменены)')
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/home/deploy/app'))
    parser.add_argument('--output', type=Path, default=Path('/home/deploy/caddy/staged'))
    parser.add_argument('--expected-nginx-sha', default='105582ad12ae7a82673a761dd1ff327a5d9c167f72955a3d759af4daf0948783')
    args = parser.parse_args()
    root = args.root.resolve()
    source = root / 'frontend/nginx.prod.conf'
    originals = {name: (root / name).read_bytes() for name in
                 ['frontend/nginx.prod.conf', 'docker-compose.prod.yml', 'docker-compose.deploy.yml']}
    hashes = {name: hashlib.sha256(value).hexdigest() for name, value in originals.items()}
    require(hashlib.sha256(source.read_bytes()).hexdigest() == args.expected_nginx_sha,
            'Nginx изменился после сверки хеша; подготовка остановлена')
    network = json.loads(run(['docker', 'network', 'inspect', 'baza_proxy']))[0]
    members = [member['Name'] for member in network.get('Containers', {}).values()]
    require(set(members).issubset({'caddy', 'ai-tutor-frontend-prod'}),
            'В baza_proxy есть посторонние контейнеры; подготовка остановлена')
    configs = network['IPAM']['Config']
    subnet = next(c['Subnet'] for c in configs if ipaddress.ip_network(c['Subnet']).version == 4)
    require(subnet == '172.20.0.0/16', 'Подсеть отличается от подтверждённой')
    files = {
        'frontend/nginx.prod.conf': nginx_http(originals['frontend/nginx.prod.conf'].decode(), subnet),
        'docker-compose.prod.yml': compose_proxy(originals['docker-compose.prod.yml'].decode()),
    }
    require(not args.output.exists(), 'Output уже существует; сохраните его и укажите новый --output')
    args.output.mkdir(mode=0o700, parents=True)
    for name, content in files.items():
        path = args.output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    (args.output / 'Caddyfile').write_text(CADDYFILE)
    (args.output / 'source-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
    commit = run(['git', '-C', str(root), 'rev-parse', 'HEAD'])
    (args.output / 'base-commit.txt').write_text(commit + '\n')
    patch = ''.join(''.join(difflib.unified_diff(originals[name].decode().splitlines(True),
                    content.splitlines(True), fromfile='a/' + name, tofile='b/' + name))
                    for name, content in files.items())
    (args.output / 'baza-ingress.patch').write_text(patch)
    # Validate staged Compose without printing resolved .env.prod values.
    common = ['docker', 'compose', '--project-directory', str(root), '--env-file', str(root / '.env.prod'),
              '-f', str(args.output / 'docker-compose.prod.yml'), '-f', str(root / 'docker-compose.deploy.yml')]
    print('Checking staged Compose...', flush=True)
    config = json.loads(run(common + ['config', '--format', 'json']))
    frontend = config['services']['frontend']
    require(not frontend.get('ports'), 'Override возвращает frontend host ports; подготовка остановлена')
    require('baza_proxy' in frontend['networks'], 'Не подключена proxy-сеть')
    mounts = [value for value in frontend.get('volumes', [])
              if value.get('target') == '/etc/nginx/conf.d/default.conf']
    require(len(mounts) == 1 and Path(mounts[0]['source']).resolve() == source.resolve(),
            'Override монтирует другой Nginx config; требуется ручное ревью')
    # nginx -t in a disposable container on the existing application network.
    names = json.loads(run(['docker', 'inspect', '--format', '{{json .NetworkSettings.Networks}}',
                            'ai-tutor-frontend-prod']))
    require(len(names) == 1, 'Frontend уже имеет несколько сетей; требуется ручное ревью')
    image = run(['docker', 'inspect', '--format', '{{.Image}}', 'ai-tutor-frontend-prod'])
    check_name = 'baza-nginx-check-' + uuid.uuid4().hex[:12]
    print('Checking Nginx with current frontend image...', flush=True)
    run(['docker', 'run', '--rm', '--name', check_name, '--network', next(iter(names)),
         '--mount', 'type=bind,src=' + str((args.output / 'frontend/nginx.prod.conf').resolve()) +
         ',dst=/etc/nginx/conf.d/default.conf,readonly', image, 'nginx', '-t'])
    print('Checking Caddy (first run may download its image)...', flush=True)
    run(['docker', 'run', '--rm', '--network', 'none', '--mount',
         'type=bind,src=' + str((args.output / 'Caddyfile').resolve()) +
         ',dst=/etc/caddy/Caddyfile,readonly', 'caddy:2-alpine',
         'caddy', 'validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])
    require(all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
                for name, digest in hashes.items()), 'Исходники изменились во время проверки; подготовьте заново')
    print('BASE COMMIT: ' + commit)
    print('PREPARED: ' + str(args.output.resolve()))
    print('Compose: OK; frontend has no host ports; baza_proxy connected')
    print('nginx -t: OK (disposable container, current frontend image)')
    print('Caddy validate: OK (disposable container without network/host ports)')
    print('Running services and original files: unchanged')
    print('Review patch: ' + str(args.output / 'baza-ingress.patch'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, StopIteration, json.JSONDecodeError) as error:
        print('STOP: ' + str(error), file=sys.stderr)
        sys.exit(1)
