#!/usr/bin/env python3
"""Native metadata probes, NOT Orb mission or instruction-following validation.

Creates only a disposable filesystem fixture. Gemini may be supplied through
--gemini-bin. No model task is sent; native metadata listings are inspected.
Grok/Gemini trust settings are private to the generated fixture.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import tempfile
import threading

REPOSITORY = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('project_skills', REPOSITORY / 'shared/prepare_project_skills.py')
preparer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparer)


def codex_list(binary, cwd, environment):
    process = subprocess.Popen([binary, 'app-server', '--stdio'], cwd=cwd, env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    responses = queue.Queue()

    def receive():
        for line in process.stdout:
            try:
                responses.put(json.loads(line))
            except ValueError:
                pass
        responses.put(None)

    threading.Thread(target=receive, daemon=True).start()

    def request(identity, method, params):
        process.stdin.write(json.dumps({'id': identity, 'method': method, 'params': params}) + '\n')
        process.stdin.flush()
        while True:
            response = responses.get(timeout=20)
            if response is None:
                raise RuntimeError('Codex app-server exited before its response')
            if response.get('id') == identity:
                if 'error' in response:
                    raise RuntimeError(response['error'])
                return response

    try:
        request(1, 'initialize', {'clientInfo': {'name': 'orb-project-skills-discovery', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        process.stdin.write('{"method":"initialized"}\n')
        process.stdin.flush()
        result = request(2, 'skills/list', {'cwds': [str(cwd)], 'forceReload': True})
        return {skill['name'] for entry in result['result']['data'] for skill in entry['skills'] if skill.get('enabled')}
    finally:
        process.terminate()
        process.wait(timeout=10)


def native_list(harness, binary, cwd, environment):
    if harness == 'codex':
        return codex_list(binary, cwd, environment)
    arguments = {
        'opencode': ['debug', 'skill'],
        'grok': ['--trust', 'inspect', '--json'],
        'gemini': ['skills', 'list', '--all'],
        'claudecode': ['-p', '/skills', '--output-format', 'stream-json', '--verbose', '--no-session-persistence'],
    }[harness]
    completed = subprocess.run([binary, *arguments], cwd=cwd, env=environment, capture_output=True, text=True, timeout=30)
    if completed.returncode:
        raise RuntimeError(f'{harness} metadata listing exited {completed.returncode}')
    if harness == 'opencode':
        return {skill['name'] for skill in json.loads(completed.stdout)}
    if harness == 'grok':
        return {skill['name'] for skill in json.loads(completed.stdout)['skills']}
    if harness == 'gemini':
        return set(re.findall(r'^([a-z0-9-]+) \[Enabled\]', completed.stdout, re.M))
    for line in completed.stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get('type') == 'system' and event.get('subtype') == 'init':
            return set(event.get('skills', []))
    raise RuntimeError('Claude did not emit native skill startup metadata')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gemini-bin', default=shutil.which('gemini'))
    parser.add_argument('--output', type=Path)
    arguments = parser.parse_args()
    fixture = Path(tempfile.mkdtemp(prefix='orb-project-skills-discovery-'))
    source = fixture / 'source'
    folder = source / 'skills/orb-marker'
    (folder / 'references').mkdir(parents=True)
    (folder / 'SKILL.md').write_text('---\nname: orb-marker # synchronized project skill\ndescription: Perform the turquoise lantern check using the supporting reference.\n---\nRead references/marker.md. Report its marker and say turquoise lantern verified.\n')
    (folder / 'references/marker.md').write_text('ORB-PROJECT-SKILLS-7E981\n')
    private_gemini = fixture / 'gemini-private-user/.gemini'
    private_gemini.mkdir(parents=True)
    (private_gemini / 'settings.json').write_text(json.dumps({'security': {'folderTrust': {'enabled': False}}}))
    private_grok = fixture / 'grok-test-config.toml'
    private_grok.write_text('')
    result = {'machine': os.uname().nodename, 'platform': 'Linux' if os.uname().sysname == 'Linux' else os.uname().sysname,
              'fixture': str(fixture), 'orb_project_ids': [], 'orb_mission_ids': [], 'model_task_executed': False, 'harnesses': {}}
    for harness in preparer.NATIVE:
        binary = arguments.gemini_bin if harness == 'gemini' else shutil.which('claude' if harness == 'claudecode' else harness)
        if not binary:
            result['harnesses'][harness] = {'unavailable': 'CLI not installed'}
            continue
        cwd = fixture / harness
        cwd.mkdir()
        environment = os.environ.copy()
        environment.update(GEMINI_CLI_HOME=str(private_gemini.parent), GROK_CONFIG_PATH=str(private_grok))
        try:
            # Filesystem preparation is separate from the real native scanner
            # below. The probe handles trust only for its own disposable fixture.
            preparer.prepare(str(source), str(cwd), harness, verify=False)
            stages = []
            for stage in ['initial', 'add', 'rename', 'delete']:
                if stage == 'add':
                    extra = source / 'skills/orb-added'
                    extra.mkdir()
                    (extra / 'SKILL.md').write_text('# A plain Markdown skill for the lavender lantern check.\n')
                elif stage == 'rename':
                    (source / 'skills/orb-added').rename(source / 'skills/orb-renamed')
                elif stage == 'delete':
                    shutil.rmtree(source / 'skills/orb-renamed')
                preparer.prepare(str(source), str(cwd), harness, verify=False)
                names = native_list(harness, binary, cwd, environment)
                actual = sorted(name for name in names if name.startswith('orb-'))
                expected = sorted(['orb-marker'] + (['orb-added'] if stage == 'add' else ['orb-renamed'] if stage == 'rename' else []))
                stages.append({'stage': stage, 'discovered': actual, 'expected': expected, 'passed': actual == expected})
            result['harnesses'][harness] = {'native_binary': binary, 'symlink': (cwd / preparer.NATIVE[harness] / 'orb-marker').is_symlink(), 'stages': stages}
        except Exception as error:
            result['harnesses'][harness] = {'error': str(error)}
        finally:
            for extra in ['orb-added', 'orb-renamed']:
                shutil.rmtree(source / 'skills' / extra, ignore_errors=True)
    # Remove the final original as well. All previously used discovery entries
    # must disappear, including adapted copies, before another project can use cwd.
    shutil.rmtree(folder)
    for harness, entry in result['harnesses'].items():
        if 'native_binary' not in entry:
            continue
        try:
            cwd = fixture / harness
            preparer.prepare(str(source), str(cwd), harness, verify=False)
            actual = sorted(name for name in native_list(harness, entry['native_binary'], cwd, environment) if name.startswith('orb-'))
            entry['initial_symlink'] = entry.pop('symlink')
            entry['stages'].append({'stage': 'delete_all', 'discovered': actual, 'expected': [], 'passed': actual == []})
        except Exception as error:
            entry['error'] = str(error)
    text = json.dumps(result, indent=2)
    if arguments.output:
        arguments.output.write_text(text + '\n')
    print(text)
    return int(any('error' in entry or any(not stage['passed'] for stage in entry.get('stages', [])) for entry in result['harnesses'].values()))


if __name__ == '__main__':
    raise SystemExit(main())
