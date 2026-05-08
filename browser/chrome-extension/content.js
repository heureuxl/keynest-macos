/**
 * 在登录页注入可见入口：检测到密码框后在右下角显示「KeyNest 填入」。
 * 传统表单提交（含密码框 + 账号框）时可选保存到本机；不拦截登录流程。
 * 需扩展具备 host_permissions: http://127.0.0.1:17373/*
 */
const BRIDGE = "http://127.0.0.1:17373/api/credentials";
const SAVE_BRIDGE = "http://127.0.0.1:17373/api/save";
const WRAP_ID = "__keynest_fill_wrap__";

function tpIsVisible(el) {
  if (!el || !(el instanceof HTMLElement)) return false;
  const st = globalThis.getComputedStyle(el);
  if (st.visibility === "hidden" || st.display === "none") return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
}

/** 穿透 Shadow DOM，与 credential-fill.js 一致 */
function tpQuerySelectorAllDeep(container, selector) {
  const out = [];
  function walk(subroot) {
    if (!subroot || !subroot.querySelectorAll) return;
    try {
      subroot.querySelectorAll(selector).forEach((el) => out.push(el));
    } catch (_) {}
    subroot.querySelectorAll("*").forEach((el) => {
      if (el.shadowRoot) walk(el.shadowRoot);
    });
  }
  walk(container);
  return out;
}

function tpFindLoginPasswordInput(form) {
  const list = tpQuerySelectorAllDeep(form, 'input[type="password"]').filter((el) =>
    tpIsVisible(el)
  );
  if (!list.length) return null;
  if (list.length === 1) return list[0];
  const cur = list.find((p) => {
    const a = (p.getAttribute("autocomplete") || "").toLowerCase();
    return a.includes("current-password");
  });
  return cur || list[0];
}

const TP_USER_SELECTOR =
  'input[type="email"], input[type="text"], input[type="tel"], input[type="search"], input[type="url"], input[type="number"], input:not([type])';

function tpFindUsernameInput(form, passwordEl) {
  const candidates = Array.from(tpQuerySelectorAllDeep(form, TP_USER_SELECTOR)).filter((el) => {
    const t = (el.getAttribute("type") || "text").toLowerCase();
    if (t === "hidden" || t === "password" || t === "submit" || t === "button") return false;
    if (el === passwordEl) return false;
    return tpIsVisible(el);
  });
  if (!candidates.length) return null;
  const email = candidates.find((el) => el.type === "email");
  if (email) return email;
  const byHint = candidates.find((el) => {
    const n =
      String(el.name || "") +
      String(el.id || "") +
      String(el.getAttribute("autocomplete") || "") +
      String(el.getAttribute("aria-label") || "") +
      String(el.placeholder || "");
    return /user|login|mail|account|phone|acct|id|手机|账号|邮箱|用户名/i.test(n);
  });
  return byHint || candidates[0];
}

function tpLooksLikeClassicPasswordLogin(form) {
  const pw = tpFindLoginPasswordInput(form);
  if (!pw || !String(pw.value || "").trim()) return false;
  const user = tpFindUsernameInput(form, pw);
  if (!user) return false;
  if (!String(user.value || "").trim()) return false;
  return true;
}

document.addEventListener(
  "submit",
  async (ev) => {
    const form = ev.target;
    if (!(form instanceof HTMLFormElement)) return;
    if (!tpLooksLikeClassicPasswordLogin(form)) return;

    ev.preventDefault();

    const passwordEl = tpFindLoginPasswordInput(form);
    const usernameEl = tpFindUsernameInput(form, passwordEl);
    const password = passwordEl.value;
    const username = String(usernameEl.value || "").trim();

    const payload = {
      title: document.title || "",
      url: location.href,
      username,
      password,
    };

    let shouldPost = false;
    try {
      const q = new URL(BRIDGE);
      q.searchParams.set("url", location.href);
      const res = await fetch(q);
      if (res.ok) {
        const list = await res.json();
        const unameLower = username.toLowerCase();
        const match = Array.isArray(list)
          ? list.find((x) => String(x.username || "").trim().toLowerCase() === unameLower)
          : null;
        if (match) {
          if (match.password === password) {
            shouldPost = false;
          } else {
            shouldPost = confirm(
              "KeyNest 已保存该账号，但密码与当前输入不一致。\n\n是否用新密码更新保管库？"
            );
          }
        } else {
          shouldPost = confirm("是否将当前账号与密码保存到本机 KeyNest？");
        }
      } else {
        shouldPost = confirm(
          "无法查询本机保管库（请先解锁 KeyNest 并开启桥接）。\n\n仍尝试保存账号密码吗？"
        );
      }
    } catch (_) {
      shouldPost = confirm("无法连接 KeyNest。\n\n仍尝试保存账号密码吗？");
    }

    if (shouldPost) {
      fetch(SAVE_BRIDGE, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        keepalive: true,
      }).catch(() => {});
    }

    const sub = ev.submitter;
    if (sub && sub.name) {
      let hid = form.querySelector('input[type="hidden"][data-keynest-autofill="submitter"]');
      if (!hid) {
        hid = document.createElement("input");
        hid.type = "hidden";
        hid.dataset.keynestAutofill = "submitter";
        form.appendChild(hid);
      }
      hid.name = sub.name;
      hid.value = sub.value || "";
    }

    HTMLFormElement.prototype.submit.call(form);
  },
  true
);

function hasPasswordField() {
  return tpQuerySelectorAllDeep(document.documentElement, 'input[type="password"]').some((el) =>
    tpIsVisible(el)
  );
}

function removeWidget() {
  document.getElementById(WRAP_ID)?.remove();
}

async function fillInputs(cred) {
  const fn = globalThis.__keynestFillCredentials;
  if (typeof fn !== "function") return { ok: false, reason: "填充脚本未加载" };
  const ret = fn(cred);
  return ret && typeof ret.then === "function" ? await ret : { ok: true };
}

function tpPickLabel(cred) {
  const u = cred.username ? String(cred.username) : "（无用户名）";
  const t = cred.title ? String(cred.title) : "";
  return t ? `${u} — ${t}` : u;
}

async function onFillClick(btn, hint, pickWrap) {
  pickWrap.innerHTML = "";
  pickWrap.style.display = "none";
  hint.textContent = "连接本机…";
  btn.disabled = true;
  try {
    const u = new URL(BRIDGE);
    u.searchParams.set("url", location.href);
    const res = await fetch(u);
    if (!res.ok) {
      hint.textContent = `失败 ${res.status}：请确认桌面端已解锁且打开「桥接」`;
      btn.disabled = false;
      return;
    }
    const list = await res.json();
    if (!Array.isArray(list) || list.length === 0) {
      hint.textContent = "无匹配：请在桌面端填写该站的域名或网址（按主机名匹配）";
      btn.disabled = false;
      return;
    }
    const choices = list.slice(0, 10);
    if (choices.length === 1) {
      const result = await fillInputs(choices[0]);
      hint.textContent = result.ok ? "已填入" : result.reason || "填入未生效，请手动输入";
      setTimeout(() => {
        hint.textContent = "来自本机 KeyNest";
        btn.disabled = false;
      }, result.ok ? 1500 : 3500);
      return;
    }
    hint.textContent = "请选择要填入的账号";
    pickWrap.style.display = "flex";
    choices.forEach((cred) => {
      const sub = document.createElement("button");
      sub.type = "button";
      sub.textContent = tpPickLabel(cred);
      sub.className = "pick-btn";
      sub.addEventListener("click", async () => {
        const result = await fillInputs(cred);
        pickWrap.innerHTML = "";
        pickWrap.style.display = "none";
        hint.textContent = result.ok ? "已填入" : result.reason || "填入未生效";
        setTimeout(() => {
          hint.textContent = "来自本机 KeyNest";
          btn.disabled = false;
        }, result.ok ? 1500 : 3500);
      });
      pickWrap.appendChild(sub);
    });
    btn.disabled = false;
  } catch (e) {
    hint.textContent = "无法连接本机，请确认 KeyNest 正在运行";
    btn.disabled = false;
  }
}

function mountWidget() {
  if (!hasPasswordField()) {
    removeWidget();
    return;
  }
  if (document.getElementById(WRAP_ID)) return;

  const wrap = document.createElement("div");
  wrap.id = WRAP_ID;
  wrap.setAttribute("data-keynest", "1");

  const shadow = wrap.attachShadow({ mode: "open" });
  const style = document.createElement("style");
  style.textContent = `
    :host { all: initial; }
    .box {
      position: fixed;
      right: 16px;
      bottom: 16px;
      z-index: 2147483647;
      font-family: system-ui, -apple-system, sans-serif;
      font-size: 13px;
      display: flex;
      flex-direction: column;
      align-items: flex-end;
      gap: 6px;
      max-width: min(320px, calc(100vw - 32px));
    }
    button {
      cursor: pointer;
      padding: 10px 14px;
      border-radius: 10px;
      border: 1px solid rgba(0,0,0,.12);
      background: linear-gradient(180deg, #f8fafc 0%, #e2e8f0 100%);
      color: #0f172a;
      font-weight: 600;
      box-shadow: 0 4px 14px rgba(15,23,42,.18);
    }
    button:hover:not(:disabled) { filter: brightness(1.05); }
    button:disabled { opacity: .65; cursor: wait; }
    .hint {
      font-size: 11px;
      color: #64748b;
      text-align: right;
      line-height: 1.35;
      text-shadow: 0 0 8px #fff, 0 0 8px #fff;
    }
    .pick {
      display: none;
      flex-direction: column;
      align-items: stretch;
      gap: 6px;
      width: 100%;
    }
    .pick-btn {
      cursor: pointer;
      padding: 8px 10px;
      border-radius: 8px;
      border: 1px solid rgba(0,0,0,.1);
      background: #fff;
      color: #0f172a;
      font-size: 12px;
      font-weight: 500;
      text-align: left;
      line-height: 1.3;
      box-shadow: 0 2px 8px rgba(15,23,42,.08);
    }
    .pick-btn:hover {
      background: #f1f5f9;
    }
  `;

  const box = document.createElement("div");
  box.className = "box";

  const hint = document.createElement("div");
  hint.className = "hint";
  hint.textContent = "来自本机 KeyNest";

  const pickWrap = document.createElement("div");
  pickWrap.className = "pick";

  const btn = document.createElement("button");
  btn.type = "button";
  btn.textContent = "KeyNest 填入";
  btn.addEventListener("click", () => onFillClick(btn, hint, pickWrap));

  box.appendChild(hint);
  box.appendChild(pickWrap);
  box.appendChild(btn);
  shadow.appendChild(style);
  shadow.appendChild(box);

  (document.body || document.documentElement).appendChild(wrap);
}

function syncWidget() {
  if (!document.body) return;
  if (hasPasswordField()) mountWidget();
  else removeWidget();
}

const mo = new MutationObserver(() => {
  syncWidget();
});
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => {
    syncWidget();
    mo.observe(document.documentElement, { childList: true, subtree: true });
  });
} else {
  syncWidget();
  mo.observe(document.documentElement, { childList: true, subtree: true });
}
