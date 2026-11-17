"use strict";
const el = id => document.getElementById(id);
let sessionId = "";
let retryFingerprint = "";
let retryRequestId = "";
let pending = new AbortController();

function resetConversation() {
  pending.abort();
  pending = new AbortController();
  sessionId = "";
  retryFingerprint = "";
  retryRequestId = "";
  el("messages").replaceChildren();
  el("approvals").replaceChildren();
  el("session").textContent = "لا توجد جلسة";
  el("prompt").value = "";
  el("status").textContent = "";
  el("send").disabled = false;
}

el("key").addEventListener("input", resetConversation);

async function api(path, options = {}) {
  const response = await fetch(path, {
    signal: pending.signal,
    ...options,
    headers: {"Content-Type": "application/json", "X-API-Key": el("key").value, ...options.headers}
  });
  const data = await response.json();
  if (!response.ok) throw Error(data.detail || "فشل الطلب");
  return data;
}
function showError(error) {
  if (error.name !== "AbortError") el("status").textContent = error.message;
}
function addMessage(role, content) {
  const div = document.createElement("div");
  div.className = "msg " + role;
  div.textContent = (role === "user" ? "أنت: " : "المساعد: ") + content;
  el("messages").append(div);
  el("messages").scrollTop = el("messages").scrollHeight;
}
el("start").onclick = async () => {
  resetConversation();
  const request = pending;
  try {
    const data = await api("/sessions", {method: "POST"});
    if (request !== pending) return;
    sessionId = data.session_id;
    retryFingerprint = ""; retryRequestId = "";
    el("session").textContent = "الجلسة: " + sessionId;
    el("messages").replaceChildren(); el("status").textContent = "";
  } catch (e) { showError(e); }
};
el("load").onclick = async () => {
  const request = pending;
  if (!sessionId) return showError(Error("أنشئ جلسة أولًا"));
  try {
    const data = await api("/sessions/" + encodeURIComponent(sessionId) + "/messages");
    if (request !== pending) return;
    el("messages").replaceChildren();
    data.messages.forEach(m => addMessage(m.role, m.content));
  } catch (e) { showError(e); }
};
el("send").onclick = async () => {
  const message = el("prompt").value.trim();
  const provider = el("provider").value;
  if (!sessionId || !message) return showError(Error("أنشئ جلسة واكتب رسالة"));
  const request = pending;
  const includeContext = el("context").checked;
  const fingerprint = JSON.stringify([sessionId, message, provider, includeContext]);
  const requestId = fingerprint === retryFingerprint && retryRequestId ? retryRequestId : crypto.randomUUID();
  retryFingerprint = fingerprint; retryRequestId = requestId;
  el("send").disabled = true; el("status").textContent = "جاري المعالجة...";
  try {
    const data = await api("/chat", {method: "POST", body: JSON.stringify({
      session_id: sessionId, message, provider, request_id: requestId, include_context: includeContext
    })});
    if (request !== pending) return;
    addMessage("user", message); addMessage("assistant", data.answer);
    el("prompt").value = ""; el("status").textContent = "تم";
    retryFingerprint = ""; retryRequestId = "";
  } catch (e) { showError(e); }
  finally { if (request === pending) el("send").disabled = false; }
};
el("refresh").onclick = async () => {
  const request = pending;
  try {
    const data = await api("/approvals");
    if (request !== pending) return;
    el("approvals").replaceChildren();
    if (!data.approvals.length) { el("approvals").textContent = "لا توجد طلبات"; return; }
    for (const item of data.approvals) {
      const div = document.createElement("div");
      div.className = "msg";
      const payload = item.payload && Object.keys(item.payload).length
        ? " — " + JSON.stringify(item.payload).slice(0, 120) : "";
      div.textContent = item.action + payload + " — " + item.status + " ";
      if (item.status === "pending") for (const [label, approve] of [["موافقة", true], ["رفض", false]]) {
        const button = document.createElement("button"); button.textContent = label;
        button.onclick = async () => {
          try {
            await api("/approvals/" + encodeURIComponent(item.id) + "/decision", {
              method: "POST", body: JSON.stringify({approve})
            });
            el("refresh").click();
          } catch (e) { showError(e); }
        };
        div.append(button);
      }
      el("approvals").append(div);
    }
  } catch (e) { showError(e); }
};
