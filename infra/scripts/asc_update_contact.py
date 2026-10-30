"""Audit or replace HumTrack's old contact address in App Store metadata only."""
import base64
import json
import os
import re
import sys
import time
from pathlib import Path
import jwt
import requests

NOTICE = '--notice' in sys.argv
APPLY = '--apply' in sys.argv or NOTICE
OLD, NEW = 'heobusy@gmail.com', 'humtrack@gmail.com'
BASE = 'https://api.appstoreconnect.apple.com'
raw = os.environ['ASC_API_KEY_P8']
key = raw if 'BEGIN PRIVATE KEY' in raw else base64.b64decode(''.join(raw.split())).decode()
now = int(time.time())
token = jwt.encode({'iss':os.environ['ASC_ISSUER_ID'],'iat':now,'exp':now+600,'aud':'appstoreconnect-v1'},key,algorithm='ES256',headers={'kid':os.environ['ASC_KEY_ID'],'typ':'JWT'})
s=requests.Session(); s.headers['Authorization']='Bearer '+token
def get(path,params=None):
    r=s.get(BASE+path,params=params,timeout=45)
    if not r.ok: raise RuntimeError(f'GET {path}: {r.status_code}')
    return r.json()
apps=get('/v1/apps',{'filter[bundleId]':'com.humtrack.app'})['data']
assert len(apps)==1,'Expected the HumTrack app only'
app=apps[0]
versions=get(f'/v1/apps/{app["id"]}/appStoreVersions',{'limit':200})['data']
live_states={'READY_FOR_SALE','READY_FOR_DISTRIBUTION'}
latest_live={}
for version in versions:
    a=version['attributes']
    if a['appStoreState'] in live_states:
        platform=a['platform']
        key=tuple(int(n) for n in a['versionString'].split('.'))
        if platform not in latest_live or key>latest_live[platform][0]: latest_live[platform]=(key,version['id'])
report={'app':app['id'],'mode':'notice' if NOTICE else 'apply' if APPLY else 'audit','versions':[],'changed':[],'blocked':[]}
obsolete={'REPLACED_WITH_NEW_VERSION','REMOVED_FROM_SALE','DEVELOPER_REMOVED_FROM_SALE','DEVELOPER_REJECTED','REJECTED','INVALID_BINARY'}
for version in versions:
    attrs=version['attributes']; state=attrs['appStoreState']
    if state in obsolete: continue
    if state in live_states and version['id']!=latest_live[attrs['platform']][1]: continue
    row={'id':version['id'],'version':attrs['versionString'],'state':state,'localizations':[]}
    for loc in get(f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations',{'limit':200})['data']:
        fields={k:v for k,v in loc['attributes'].items() if k in ['description','promotionalText','supportUrl','marketingUrl'] and isinstance(v,str)}
        replacements={k:v.replace(OLD,NEW) for k,v in fields.items() if OLD in v}
        info={'id':loc['id'],'locale':loc['attributes']['locale'],'emails':sorted(set(re.findall(r'[\w.+-]+@[\w.-]+',' '.join(fields.values())))),'old_address_fields':list(replacements)}
        row['localizations'].append(info)
        if NOTICE:
            original=fields.get('promotionalText','').strip()
            locale=info['locale']
            notice='문의: humtrack@gmail.com.' if locale=='ko' else 'Support: humtrack@gmail.com.'
            text=original.replace(OLD,NEW)
            if NEW not in text:
                # Preserve the product introduction; omit the existing trial sentence only if needed for Apple's 170-character limit.
                candidate=notice+' '+text
                if len(candidate)>170 and text.endswith('Start free for 7 days.'):
                    text=text[:-len('Start free for 7 days.')].rstrip()
                    candidate=notice+' '+text
                text=candidate
            if len(text)>170:
                report['blocked'].append({'locale':locale,'reason':'Notice exceeds 170 characters; existing text preserved'})
                continue
            replacements={'promotionalText':text} if text!=original else {}
        if APPLY and replacements:
            path=f'/v1/appStoreVersionLocalizations/{loc["id"]}'
            r=s.patch(BASE+path,json={'data':{'type':'appStoreVersionLocalizations','id':loc['id'],'attributes':replacements}},timeout=45)
            if not r.ok:
                report['blocked'].append({'version':row['version'],'state':state,'locale':info['locale'],'status':r.status_code,'errors':[{k:e.get(k) for k in ['code','title','detail']} for e in r.json().get('errors',[])]})
                continue
            actual=get(path)['data']['attributes']
            assert all(actual[k]==v for k,v in replacements.items()),'Contact readback mismatch'
            assert all(actual[k]==v for k,v in fields.items() if k not in replacements),'Unrelated metadata changed'
            report['changed'].append({'version':row['version'],'locale':info['locale'],'fields':list(replacements),'verified':True,**({'promotionalText':actual['promotionalText']} if NOTICE else {})})
            info['emails']=sorted(set(re.findall(r'[\w.+-]+@[\w.-]+',' '.join(str(actual.get(k,'')) for k in fields))))
    report['versions'].append(row)
output=Path('artifacts/store-contact-20261030'); output.mkdir(parents=True,exist_ok=True)
(output/f'asc-{report["mode"]}.json').write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding='utf-8')
print(json.dumps(report,indent=2,ensure_ascii=False))
