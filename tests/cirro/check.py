#!/usr/bin/env python3
"""Exercise unchanged Cirro specs from a separate checkout against this extension.

Requires PyYAML. Example:
  python tests/cirro/check.py --cirro-root ../cirro --extension build/graphqlite.dylib
The external templates are read at runtime, never copied into this repository.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys

import yaml


def load_specs(root):
    base = root / 'src/graph/config'
    constants = yaml.safe_load((base / 'constants.yaml').read_text())
    specs = {}
    def replace(match):
        group, key = match[1].split('.')
        return constants[group][key]
    for path in sorted(base.rglob('*.tera.yaml')):
        rendered = re.sub(r'\{\{\s*([\w.]+)\s*\}\}', replace, path.read_text())
        if '{{' in rendered or '{%' in rendered:
            raise ValueError(f'Unsupported template construct: {path}')
        specs[str(path.relative_to(base))] = yaml.safe_load(rendered)
    return specs


class Graph:
    def __init__(self, extension, specs, runner=None):
        self.process = None
        if runner:
            self.process = subprocess.Popen([str(runner), str(extension)], stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, text=True)
        else:
            self.db = sqlite3.connect(':memory:')
            self.db.enable_load_extension(True)
            self.db.load_extension(str(extension))
            self.db.enable_load_extension(False)
        self.specs = specs

    def request(self, op, **args):
        self.process.stdin.write(json.dumps({'op': op, **args}) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f'Rust runner exited: {self.process.poll()}')
        result = json.loads(line)
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['value']

    def metadata(self):
        if self.process:
            return self.request('metadata')
        return {'sqlite_version': sqlite3.sqlite_version,
                'capabilities': json.loads(self.db.execute('SELECT cypher_capabilities()').fetchone()[0])}

    def validate(self, query):
        if self.process:
            return self.request('validate', query=query)
        return json.loads(self.db.execute('SELECT cypher_validate(?)', (query,)).fetchone()[0])

    def query(self, query, params=None):
        if self.process:
            return self.request('query', query=query, params=params or {})
        raw = self.db.execute('SELECT cypher(?,?)', (query, json.dumps(params or {}))).fetchone()[0]
        result = json.loads(raw)
        if isinstance(result, dict) and 'error' in result:
            raise RuntimeError(result['error'])
        return result

    def close(self):
        if self.process:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process.stdout.close()
        else:
            self.db.close()

    def spec(self, path, **params):
        return self.query(self.specs[path]['cypher'], params)

    def nodes(self):
        return self.query('MATCH (n) RETURN n.id AS id, labels(n) AS labels, properties(n) AS properties')

    def edges(self):
        return {(r['src'], r['rel'], r['dst']) for r in self.query(
            'MATCH (a)-[r]->(b) RETURN a.id AS src, type(r) AS rel, b.id AS dst')}

    def snapshot(self):
        # Internal IDs are transport identities, not the data being compared.
        nodes = self.query('MATCH (n) RETURN id(n) AS internal, labels(n) AS labels, properties(n) AS properties')
        key = {n['internal']: json.dumps([sorted(n['labels']), n['properties']], sort_keys=True) for n in nodes}
        edges = self.query('MATCH (a)-[r]->(b) RETURN id(a) AS src, id(b) AS dst, type(r) AS rel, properties(r) AS properties')
        return sorted(key.values()), sorted(json.dumps([key[e['src']], e['rel'], key[e['dst']], e['properties']], sort_keys=True) for e in edges)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def users_groups(g):
    users = [dict(id='U1', displayName='Alice', accountEnabled=True, userPrincipalName='alice@example.test', memberOf=['G1'], manager='U2'),
             dict(id='U2', displayName='Bob', accountEnabled=False, memberOf=[])]
    groups = [dict(id='G1', displayName='Team', memberOf=[], owners=['U2'], members=['U1'], securityEnabled=True)]
    for row in users + groups:
        row['@odata.type'] = '#microsoft.graph.directoryObject'
    def ingest():
        g.spec('azure/msgraph/users.tera.yaml', batch=users)
        g.spec('azure/msgraph/groups.tera.yaml', batch=groups)
    ingest()
    nodes = {n['id']: n for n in g.nodes()}
    require(set(nodes) == {'u1', 'u2', 'g1'}, f'Unexpected nodes: {nodes}')
    require(nodes['u1']['properties']['accountEnabled'] is True, 'True property lost')
    require(nodes['u2']['properties']['accountEnabled'] is False, 'False property lost')
    require(all(n['properties'].get('odataType') == '#microsoft.graph.directoryobject' for n in nodes.values()), 'OData type expression lost')
    require(set(nodes['u1']['labels']) == {'GraphObject', 'GraphUser'}, 'User labels changed')
    require(g.edges() == {('u1', 'MEMBER_OF', 'g1'), ('u2', 'MANAGES', 'u1'), ('u2', 'OWNS', 'g1')}, f'Wrong relationships: {g.edges()}')
    before = g.snapshot(); ingest(); require(g.snapshot() == before, 'Repeated users/groups ingestion changed graph')


def conditional_resources(g):
    rows = [dict(id='r1', _rg_id='rg', name='With identity', tags={'env': 'test'}, managedBy='host',
                 identity={'type': 'SystemAssigned', 'principalId': 'sp'}, properties={'privateEndpointConnections': [{'id':'ep','name':'endpoint','type':'privateEndpoint','properties':{'groupIds':['web']}}]}),
            dict(id='r2', _rg_id='rg', name='Without identity', tags={}, properties={})]
    def ingest(): g.spec('azure/arm/resource_management/generic_arm_resources.tera.yaml', batch=rows)
    ingest()
    expected = {('rg','CONTAINS','r1'),('rg','CONTAINS','r2'),('host','MANAGES','r1'),('r1','HAS_IDENTITY','sp'),('r1','HAS_PRIVATE_ENDPOINT','ep')}
    require(g.edges() == expected, f'Conditional branch graph differs: {g.edges()}')
    require({n['id'] for n in g.nodes()} == {'r1','r2','rg','host','sp','ep'}, 'Conditional import lost or added nodes')
    props = {n['id']: n['properties'] for n in g.nodes()}
    require(props['r1'].get('tags') == ['env:test'] and props['r2'].get('tags') == [], 'Nonempty/empty resource tags lost')
    before = g.snapshot(); ingest(); require(g.snapshot() == before, 'Conditional import is not idempotent')


def nested_network(g):
    props = {'addressSpace':{'addressPrefixes':['10.0.0.0/16']}, 'subnets':[{'id':'sn','name':'subnet','properties':{'routeTable':{'id':'rt'},'networkSecurityGroup':{'id':'nsg'}}}],
             'virtualNetworkPeerings':[{'id':'peer','name':'peering','properties':{'remoteVirtualNetwork':{'id':'remote'},'allowVirtualNetworkAccess':True}}]}
    def ingest(): g.spec('azure/arm/network/virtual_networks.tera.yaml', batch=[{'id':'net','properties':props}])
    ingest()
    expected = {('net','CONTAINS','sn'),('sn','HAS_CONFIG','rt'),('sn','HAS_NSG','nsg'),('net','HAS_PEERING','peer'),('peer','PEERS_WITH','remote')}
    require(g.edges() == expected, f'Nested scopes changed endpoints: {g.edges()}')
    before = g.snapshot(); ingest(); require(g.snapshot() == before, 'Nested scopes are not idempotent')


def dynamic_properties(g):
    props = {'subnetId':'subnet','connectionUrls':{'serviceUrl':'https://db.example.test','jdbcUrl':'jdbc:oracle:test'},'isMtlsConnectionRequired':True}
    g.spec('azure/arm/oracle/oracle_autonomous_db.tera.yaml', batch=[{'id':'db','properties':props}])
    n = next(n for n in g.nodes() if n['id'] == 'db')
    require(n['properties']['serviceUrl'] == props['connectionUrls']['serviceUrl'], 'Dynamic property missing')
    require(n['properties']['jdbcUrl'] == props['connectionUrls']['jdbcUrl'], 'Second dynamic property missing')
    require(g.edges() == {('subnet','HAS_ORACLE_RESOURCE','db')}, 'Dynamic-property import changed relationship')


def dynamic_relationship(g):
    row = {'id':'assignment','roleName':'Custom Reader','description':'sample','permissions':[{'actions':['read'],'notActions':[],'dataActions':[],'notDataActions':[]}],
           'properties':{'principalId':'user','scope':'scope','roleDefinitionId':'role'},'type':'roleAssignments'}
    def ingest(): g.spec('azure/arm/authorization/role_assignments.tera.yaml', batch=[row])
    ingest()
    require(g.edges() == {('user','CustomReader','scope')}, f'Dynamic relationship type lost: {g.edges()}')
    r = g.query('MATCH ()-[r]->() RETURN properties(r) AS p')[0]['p']
    require(r['actions'] == ['read'] and r['id'] == 'assignment', f'Role properties differ: {r}')
    before=g.snapshot(); ingest(); require(g.snapshot()==before, 'Dynamic relationship import is not idempotent')


def tailscale(g):
    data={'CurrentTailnet':{'Name':'example.test','MagicDNSEnabled':True},'Self':{'ID':'dev1','UserID':1,'Hostname':'one','Online':True,'TailscaleIPs':['100.64.0.1']},
          'Peer':{'key2':{'ID':'dev2','UserID':2,'Hostname':'two','Online':False}},'User':{'1':{'ID':1,'LoginName':'alice@example.test'},'2':{'ID':2,'LoginName':'bob@example.test'}}}
    def ingest():
        for f in ['tailnet','user','devices']:g.spec(f'tailscale/status/{f}.tera.yaml',status_data=data)
    ingest()
    require(g.edges()=={('example.test','CONTAINS','dev1'),('example.test','CONTAINS','dev2'),('1','OWNS','dev1'),('2','OWNS','dev2')}, f'Tailscale topology differs: {g.edges()}')
    require(len(g.nodes())==5, 'Wrong Tailscale node count')
    before=g.snapshot();ingest();require(g.snapshot()==before, 'Tailscale ingestion is not idempotent')


def serialized_settings(g):
    settings = {'vmType':'sample','enabled':True,'ports':[80,443],'literal':'[1]'}
    g.spec('azure/arm/compute/virtual_machine_extensions.tera.yaml',
           batch=[{'id':'extension','properties':{'settings':settings,'autoUpgradeMinorVersion':False}}])
    props = g.nodes()[0]['properties']
    require(isinstance(props['settings'], str), 'APOC JSON must be a string property')
    require(json.loads(props['settings']) == settings, f'Settings lost JSON types: {props}')
    require(props['autoUpgradeMinorVersion'] is False, 'False ARM property lost')


def vault_versions(g):
    certificate='https://vault.example.test/certificates/sample/v1'
    secret='https://vault.example.test/secrets/sample/v1'
    def ingest():
        g.spec('azure/arm/keyvault/key_vault_cert_value.tera.yaml', batch=[
            {'id':certificate,'name':'sample','x509ThumbprintHex':'test-thumbprint',
             'attributes':{'enabled':True},'policy':{},'tags':{'env':'test'}}])
        g.spec('azure/arm/keyvault/key_vault_secret_value.tera.yaml', batch=[
            {'id':secret,'name':'sample','value':'abc7Q~synthetic-fixture',
             'attributes':{'enabled':False},'tags':{}}])
    ingest()
    require(g.edges() == {(certificate.rsplit('/',1)[0],'HAS_VERSION',certificate),
                          (secret.rsplit('/',1)[0],'HAS_VERSION',secret)},
            f'Projected imports or regex parent IDs differ: {g.edges()}')
    props = {n['id']: n['properties'] for n in g.nodes()}
    require(props[certificate].get('tags') == ['env:test'] and props[secret].get('tags') == [], 'Nonempty/empty vault tags lost')
    before=g.snapshot();ingest();require(g.snapshot()==before, 'Vault versions are not idempotent')
    g.query('CREATE (:ClientSecret {id:"credential", hint:"abc"})')
    g.spec('post_processing/match_vault_secrets_to_creds.tera.yaml')
    require((secret,'MATCHES_SECRET','credential') in g.edges(), 'Periodic matching lost producer entities')


def postprocessing(g):
    g.query('CREATE (a:GraphObject:GraphUser {id:"USER", userPrincipalName:"alice@example.test", name:"Alice"}), (b:GraphObject:GraphUser {id:"user", userPrincipalName:"alice@example.test", name:"Alicia"}), (t:TSUser {id:"ts", loginName:"alice@example.test"}), (x:GraphObject {id:"owner"}), (x)-[:OWNS {source:"a"}]->(a), (x)-[:OWNS {source:"b"}]->(b)')
    jobs=sorted(((p,s) for p,s in g.specs.items() if p.startswith('post_processing/')),key=lambda item:(item[1].get('priority',0),item[0]))
    def run():
        for p,_ in jobs:g.spec(p)
    run()
    users=g.query('MATCH (n:GraphUser) RETURN n.id AS id, n.name AS name')
    require(len(users)==1 and users[0]['id']=='user', f'Deduplication failed: {users}')
    require(set(users[0]['name'])=={'Alice','Alicia'}, f'Conflicting names were lost: {users}')
    require(('ts','SAME_USER','user') in g.edges(), f'Cross-platform identity link missing: {g.edges()}')
    owned=g.query('MATCH (:GraphObject {id:"owner"})-[r:OWNS]->(:GraphUser) RETURN r.source AS sources')
    require(len(owned)==1 and set(owned[0]['sources'])=={'a','b'}, f'Incident edge properties were lost: {owned}')
    before=g.snapshot();run();require(g.snapshot()==before, 'Postprocessing is not idempotent')


def set_expression_failures(g):
    g.query('CREATE (:SetFailure {id:1, before:"original", keep:true})')
    before = g.snapshot()
    for expression in ['unknownSetFunction(1)', 'apoc.text.replace("x", "[", "")']:
        try:
            g.query('MATCH (n:SetFailure) SET n.before="changed", n.fresh=42 '
                    'SET n += {bad:' + expression + '}')
        except Exception:
            pass
        else:
            raise AssertionError('Failed SET expression was silently omitted: ' + expression)
        require(g.snapshot() == before, 'Failed SET did not roll back preceding property writes')
    # Quoted, escaped, and long property names are decoded without truncation.
    key = 'quoted"\\key' + 'long' * 100
    g.query('MATCH (n:SetFailure) SET n += $props', {'props': {key: [True, False], 'raw': '[true]'}})
    props = g.query('MATCH (n:SetFailure) RETURN properties(n) AS p')[0]['p']
    require(props.get(key) == [True, False] and props.get('raw') == '[true]', 'Parameter map keys or types changed')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cirro-root',required=True,type=Path)
    parser.add_argument('--extension',required=True,type=Path)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--rust-runner',type=Path,help='Optional rust-runner binary using Cirro\'s pinned rusqlite')
    args=parser.parse_args();specs=load_specs(args.cirro_root);extension=args.extension.resolve()
    runner=args.rust_runner.resolve() if args.rust_runner else None
    g=Graph(extension,specs,runner)
    report={**g.metadata(),'backend':'rust' if runner else 'extension','validation':[],'postprocessing_empty':[],'fixtures':[]}
    report['cirro_commit']=subprocess.check_output(['git','-C',str(args.cirro_root),'rev-parse','HEAD'],text=True).strip()
    for path,spec in specs.items():
        validation=g.validate(spec['cypher']);report['validation'].append({'file':path,**validation})
        if path.startswith('post_processing/'):
            c=Graph(extension,specs,runner)
            try:c.spec(path);report['postprocessing_empty'].append({'file':path,'passed':True})
            except Exception as e:report['postprocessing_empty'].append({'file':path,'passed':False,'error':str(e)})
            finally:c.close()
    for fn in [users_groups,conditional_resources,nested_network,dynamic_properties,dynamic_relationship,tailscale,serialized_settings,vault_versions,postprocessing,set_expression_failures]:
        c=Graph(extension,specs,runner)
        try:fn(c);report['fixtures'].append({'name':fn.__name__,'passed':True})
        except Exception as e:report['fixtures'].append({'name':fn.__name__,'passed':False,'error':str(e)})
        finally:c.close()
    g.close()
    failed=False
    for section,key in [('validation','valid'),('postprocessing_empty','passed'),('fixtures','passed')]:
        passing=sum(bool(r.get(key)) for r in report[section]);print(f'{section}: {passing}/{len(report[section])}')
        for r in report[section]:
            if not r.get(key):failed=True;print('FAIL',r.get('file',r.get('name')),r.get('error'))
    if args.output:args.output.write_text(json.dumps(report,indent=2)+'\n')
    return int(failed)

if __name__=='__main__':sys.exit(main())
