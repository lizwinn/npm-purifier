# SPDX-License-Identifier: MIT
import json, os
from pathlib import Path
import subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit
repository = Path(sys.argv[1])
catalog = Path(sys.argv[2])
modules=json.loads(catalog.read_text())['modules']
class Registry(BaseHTTPRequestHandler):
    def do_GET(self):
        route=unquote(urlsplit(self.path).path).lstrip('/')
        if route.startswith('tarballs/'):
            body=(repository/route).read_bytes()
        else:
            available=[module for module in modules if module['name']==route]
            if not available:
                self.send_error(404);return
            versions={}
            for module in available:
                metadata=dict(module['package'])
                metadata['dist']={'integrity':module['integrity'],'tarball':'http://'+self.headers['Host']+'/'+module['archive']}
                versions[module['version']]=metadata
            body=json.dumps({'name':route,'versions':versions,'dist-tags':{'latest':available[0]['version']}}).encode()
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Registry)
threading.Thread(target=server.serve_forever,daemon=True).start()
node=Path(sys.argv[3])
try:
    with tempfile.TemporaryDirectory(prefix='npm-real-downstream-') as directory:
        root=Path(directory)
        (root/'package.json').write_text('{"name":"ordinary-consumer","private":true}')
        env=dict(os.environ,PATH=str(node)+':'+os.environ['PATH'],npm_config_cache=str(root/'cache'),npm_config_update_notifier='false')
        version=next(module['version'] for module in modules if module['name']=='greet-cli')
        subprocess.run([str(node/'npm'),'install','--no-audit','--no-fund','--registry',f'http://127.0.0.1:{server.server_port}/','greet-cli@'+version],cwd=root,env=env,check=True)
        if len(sys.argv) > 4:
            (root/'package.json').write_text(json.dumps({'name':'purified-consumer','private':True,'dependencies':{'greet-cli':'>=99'}}))
            (root/'package-lock.json').unlink()
            (root/'views.json').write_text(json.dumps([{'repository':str(repository),'catalog':str(catalog)}]))
            import shutil
            shutil.rmtree(root/'node_modules')
            shutil.rmtree(root/'cache')
            env.update(NODE_OPTIONS='--require='+sys.argv[4], NPM_PURIFIER_INPUT_VIEWS=str(root/'views.json'),
                       NPM_PURIFIER_NPM_MODULES=str(node.parent/'lib/node_modules/npm/node_modules'), npm_config_offline='true')
            before=(root/'package.json').read_bytes()
            subprocess.run([str(node/'npm'),'install','--no-audit','--no-fund'],cwd=root,env=env,check=True)
            assert (root/'package.json').read_bytes()==before
            lock=json.loads((root/'package-lock.json').read_text())
            for item in lock['packages'].values():
                if 'resolved' in item:
                    item['resolved']='file:///nix/store/00000000000000000000000000000000-absent/'+Path(item['resolved']).name
                    item['version']='99.0.0-nix.h'+'0'*64
            (root/'package-lock.json').write_text(json.dumps(lock))
            before_lock=(root/'package-lock.json').read_bytes()
            subprocess.run([str(node/'npm'),'ci','--no-audit','--no-fund'],cwd=root,env=env,check=True)
            assert (root/'package-lock.json').read_bytes()==before_lock

        output=subprocess.check_output([str(root/'node_modules/.bin/greet'),'42'],cwd=root,env=env,text=True)
        print(output)
        assert 'hello, number 42' in output and 'esbuild:' in output
        print('REAL NIX WORKSPACE, COMPILED ESBUILD AND ORDINARY NPM CONSUMPTION PASSED')
finally:server.shutdown();server.server_close()
