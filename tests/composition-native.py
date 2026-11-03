#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Installed npm CLI source pinning and ordinary development with composed inputs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(['nix','eval','--impure','--raw','--expr','builtins.currentSystem'],text=True).strip()
snapshot = json.loads(subprocess.check_output(['nix','flake','metadata','--json','--no-write-lock-file','path:'+str(root)],text=True))['path']
with tempfile.TemporaryDirectory(prefix='npm-native-composition-') as temporary:
    temporary = Path(temporary)
    subprocess.run(['nix-store','--add-root',str(temporary/'source'),'--realise',snapshot],check=True)
    def tool(name):
        output = subprocess.check_output(['nix','build',str(root)+'#'+name,'--out-link',str(temporary/name),'--print-out-paths'],text=True).strip()
        return Path(output)/'bin'/name
    cli, npm = tool('npm-purifier'), tool('npm')
    project = temporary/'project'
    project.mkdir()
    manifest = {'name':'composed-consumer','version':'1.0.0','license':'MIT','bin':{'composed-consumer':'index.js'},'dependencies':{'greet-cli':'>=99'}}
    (project/'package.json').write_text(json.dumps(manifest))
    (project/'index.js').write_text("#!/usr/bin/env node\nrequire('greet-cli/cli.js')\n")
    original = (project/'package.json').read_bytes()
    env = dict(os.environ, npm_config_update_notifier='false',npm_config_cache=str(temporary/'cache'))
    def run(*args, **kwargs):
        return subprocess.run([str(arg) for arg in args],cwd=project,env=env,check=True,**kwargs)
    run(cli,'lock','--input','path:'+snapshot+'#checks.'+system+'.composition-producer')
    lockfile = project/'npm-purifier.lock.json'
    lock = json.loads(lockfile.read_text())
    assert len(lock['projectInputs'])==1 and not lock['git']
    before = lockfile.read_bytes(), (project/'package-lock.json').read_bytes()
    run(cli,'lock')
    assert before==(lockfile.read_bytes(),(project/'package-lock.json').read_bytes())
    assert (project/'package.json').read_bytes()==original
    run(npm,'ci')
    output=run(npm,'exec','--','greet','42',capture_output=True,text=True).stdout
    assert 'hello, number 42' in output and 'esbuild:' in output, output
    assert before==(lockfile.read_bytes(),(project/'package-lock.json').read_bytes())
    build_env = dict(env, NPM_COMPOSITION_FLAKE=snapshot, NPM_COMPOSITION_PROJECT=str(project))
    expression = '''let
      f = builtins.getFlake ("path:" + builtins.getEnv "NPM_COMPOSITION_FLAKE");
      p = import f.inputs.nixpkgs { overlays=[f.overlays.default]; };
    in p.npm-purifier.buildNpmProject {src=/. + builtins.getEnv "NPM_COMPOSITION_PROJECT";}'''
    def build(attribute):
        return Path(subprocess.check_output(['nix','build','--impure','--out-link',str(temporary/attribute.replace('.','-')),
                    '--print-out-paths','--expr','('+expression+').'+attribute],env=build_env,text=True).strip())
    installed = build('packages.composed-consumer')
    output=subprocess.check_output([str(installed/'bin/composed-consumer'),'42'],text=True)
    assert 'hello, number 42' in output and 'esbuild:' in output, output
    projected = build('projections.npm')
    metadata = json.loads(subprocess.check_output(['nix','eval','--impure','--json','--expr','('+expression+').projections.npm.catalog'],env=build_env,text=True))
    catalog = json.loads(Path(metadata).read_text())
    assert len([entry for entry in catalog['modules'] if entry['primary']])==1
    import base64
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    uploads = {}
    class Registry(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_error(404)
        def do_PUT(self):
            document=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            for attachment in document['_attachments'].values():
                data=base64.b64decode(attachment['data'])
                uploads[document['name']]=data
            self.send_response(201)
            self.end_headers()
            self.wfile.write(b'{}')
        def log_message(self,*args): pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Registry)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    registry='http://127.0.0.1:'+str(server.server_port)+'/'
    env['npm_config_userconfig']=str(temporary/'npmrc')
    (temporary/'npmrc').write_text('//127.0.0.1:'+str(server.server_port)+'/:_authToken=local-fixture\n')
    try:
        run(cli,'publish','--registry',registry,'--access','public')
    finally:
        server.shutdown()
        server.server_close()
    for entry in catalog['modules']:
        assert uploads[entry['name']]==(projected/entry['archive']).read_bytes(), entry['name']
    assert before==(lockfile.read_bytes(),(project/'package-lock.json').read_bytes())
    print('Native pinning, stable lock, development, pure build and exact publication passed')
