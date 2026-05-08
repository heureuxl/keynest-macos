const bridge = "http://127.0.0.1:17373/api/credentials";

function setMsg(t) {
  const el = document.getElementById("msg");
  if (el) el.textContent = t || "";
}

function labelCred(c) {
  const u = c.username ? String(c.username) : "—";
  const t = c.title ? String(c.title) : "";
  return t ? `${u} · ${t}` : u;
}

async function injectCred(tabId, cred) {
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ["credential-fill.js"],
  });
  const [{ result }] = await chrome.scripting.executeScript({
    target: { tabId },
    func: async (c) => {
      const fn = globalThis.__keynestFillCredentials;
      if (typeof fn !== "function") return { ok: false, reason: "填充脚本未就绪" };
      const out = fn(c);
      return out && typeof out.then === "function" ? await out : { ok: true };
    },
    args: [cred],
  });
  return result;
}

document.getElementById("go")?.addEventListener("click", async () => {
  setMsg("");
  const pick = document.getElementById("pick");
  const go = document.getElementById("go");
  if (pick) pick.innerHTML = "";
  if (go) go.style.display = "block";
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id || !tab.url) {
      setMsg("无法获取当前页。");
      return;
    }
    const u = new URL(bridge);
    u.searchParams.set("url", tab.url);
    const res = await fetch(u);
    if (!res.ok) {
      setMsg(`本机服务错误：${res.status}（请确认 KeyNest 已解锁并打开桥接）`);
      return;
    }
    const list = await res.json();
    if (!Array.isArray(list) || list.length === 0) {
      setMsg("无匹配条目：请在桌面端填写该站的域名或网址（按主机名匹配）。");
      return;
    }
    const choices = list.slice(0, 10);
    if (choices.length === 1) {
      const fillResult = await injectCred(tab.id, choices[0]);
      if (fillResult?.ok) window.close();
      else setMsg(fillResult?.reason || "填入未生效，请在本页使用右下角按钮或手动输入");
      return;
    }
    setMsg("请选择要填入的账号：");
    if (go) go.style.display = "none";
    choices.forEach((cred) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = labelCred(cred);
      b.style.marginTop = "8px";
      b.addEventListener("click", async () => {
        const fillResult = await injectCred(tab.id, cred);
        if (fillResult?.ok) window.close();
        else setMsg(fillResult?.reason || "填入未生效");
      });
      pick?.appendChild(b);
    });
  } catch (e) {
    setMsg(`连接失败：${e}. 请确认应用正在运行。`);
  }
});
