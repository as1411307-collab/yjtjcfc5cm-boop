import importlib
import os
import tempfile
from fastapi.testclient import TestClient


def test_delete_task_requires_confirmation_and_rejects_stale_or_ambiguous():
    with tempfile.TemporaryDirectory() as folder:
        os.environ['DB_PATH'] = folder + '/test.sqlite3'
        os.environ['AI_API_KEY'] = 'test-key-with-more-than-24-characters'
        import core.app as module
        importlib.reload(module)
        with TestClient(module.app) as client:
            h = {'X-API-Key': os.environ['AI_API_KEY']}
            sid = client.post('/sessions', headers=h).json()['session_id']
            task = client.post(f'/sessions/{sid}/tasks', headers=h, json={'title':'مراجعة الصوت'}).json()
            plan = client.post('/agent/plans', headers=h, json={'session_id':sid, 'command':'احذف مهمة: مراجعة الصوت'})
            assert plan.status_code == 201
            assert 'task_id' not in plan.json()['payload']
            assert '_expected_done' not in plan.json()['payload']
            assert len(client.get(f'/sessions/{sid}/tasks', headers=h).json()['tasks']) == 1
            client.patch(f'/sessions/{sid}/tasks/{task["id"]}?done=true', headers=h)
            stale = client.post(f'/agent/plans/{plan.json()["plan_id"]}/decision', headers=h, json={'execute':True})
            assert stale.status_code == 409
            assert len(client.get(f'/sessions/{sid}/tasks', headers=h).json()['tasks']) == 1
            plan = client.post('/agent/plans', headers=h, json={'session_id':sid, 'command':'احذف مهمة: مراجعة الصوت'}).json()
            assert client.post(f'/agent/plans/{plan["plan_id"]}/decision', headers=h, json={'execute':False}).json()['status'] == 'cancelled'
            plan = client.post('/agent/plans', headers=h, json={'session_id':sid, 'command':'احذف مهمة: مراجعة الصوت'}).json()
            assert client.post(f'/agent/plans/{plan["plan_id"]}/decision', headers=h, json={'execute':True}).json()['status'] == 'executed'
            assert client.get(f'/sessions/{sid}/tasks', headers=h).json()['tasks'] == []
            for _ in range(2):
                client.post(f'/sessions/{sid}/tasks', headers=h, json={'title':'مكرر'})
            assert client.post('/agent/plans', headers=h, json={'session_id':sid, 'command':'احذف مهمة: مكرر'}).status_code == 409
