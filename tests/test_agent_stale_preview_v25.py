import importlib
import os
import tempfile
from fastapi.testclient import TestClient


def test_rename_and_pin_reject_stale_previews():
    with tempfile.TemporaryDirectory() as directory:
        os.environ['DB_PATH'] = directory + '/db.sqlite3'
        os.environ['AI_API_KEY'] = 'test-key-with-more-than-24-characters'
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            h = {'X-API-Key': os.environ['AI_API_KEY']}
            sid = client.post('/sessions', headers=h).json()['session_id']
            def plan(command):
                result = client.post('/agent/plans', headers=h, json={'session_id':sid,'command':command})
                assert result.status_code == 201
                return result.json()['plan_id']
            def execute(pid):
                return client.post(f'/agent/plans/{pid}/decision',headers=h,json={'execute':True})
            old = plan('سم المحادثة: القديم')
            fresh = plan('سم المحادثة: الجديد')
            assert execute(fresh).status_code == 200
            assert execute(old).status_code == 409
            assert client.get('/sessions',headers=h).json()['sessions'][0]['title'] == 'الجديد'
            pin = plan('pin')
            rename = plan('سم المحادثة: أحدث')
            assert execute(rename).status_code == 200
            assert execute(pin).status_code == 409
