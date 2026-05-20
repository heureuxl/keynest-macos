/**
 * 在登录页注入可见入口：检测到密码框后在右下角显示「KeyNest 填入」。
 * 经典表单 submit、以及常见「登录」按钮点击（SPA / fetch 登录）后尝试保存；不拦截登录流程。
 * 需扩展具备 host_permissions: http://127.0.0.1:17373/*
 */
const BRIDGE = "http://127.0.0.1:17373/api/credentials";
const SAVE_BRIDGE = "http://127.0.0.1:17373/api/save";
const LIMIT_CHECK_BRIDGE = "http://127.0.0.1:17373/api/site-limit-check";

/** @returns {Promise<{ needsConfirm: boolean, maxAccounts?: number, currentCount?: number, siteLabel?: string, evictTitle?: string, evictUsername?: string, incomingUsername?: string } | null>} */
async function fetchSiteLimitCheck(url, username) {
  try {
    const q = new URL(LIMIT_CHECK_BRIDGE);
    q.searchParams.set("url", url);
    q.searchParams.set("username", username || "");
    const res = await fetch(q);
    if (!res.ok) return null;
    return await res.json();
  } catch (_) {
    return null;
  }
}

function formatSiteLimitConfirmMessage(limit) {
  const site = limit.siteLabel || location.hostname;
  const max = limit.maxAccounts ?? 3;
  const count = limit.currentCount ?? max;
  const incoming = String(limit.incomingUsername || "").trim() || "（无用户名）";
  const evictTitle = limit.evictTitle || "未命名";
  const evictUser = String(limit.evictUsername || "").trim() || "（无用户名）";
  return (
    `网站「${site}」已保存 ${count} 个不同账号（上限 ${max} 个）。\n\n` +
    `继续保存「${incoming}」将移除最早条目：\n${evictTitle}（${evictUser}）\n\n是否继续保存？`
  );
}

/** @param {{ needsConfirm?: boolean }} limit */
async function confirmSiteLimitIfNeeded(limit) {
  if (!limit?.needsConfirm) return true;
  return confirm(formatSiteLimitConfirmMessage(limit));
}
const WRAP_ID = "__keynest_fill_wrap__";
const HINT_ID = "__keynest_hint__";

/** @param {{ title?: string, url: string, username: string, password: string }} payload */
async function runSaveOffer(payload) {
  if (globalThis.__knSaveOfferRunning) return;
  globalThis.__knSaveOfferRunning = true;
  try {
    await runSaveOfferInner(payload);
  } finally {
    globalThis.__knSaveOfferRunning = false;
  }
}

/** @param {{ title?: string, url: string, username: string, password: string }} payload */
async function runSaveOfferInner(payload) {
  const password = String(payload.password || "").trim();
  if (!password) return;

  const now = Date.now();
  if (now - (globalThis.__knLastSaveOfferAt || 0) < 900) return;
  globalThis.__knLastSaveOfferAt = now;

  const uname = String(payload.username || "").trim();
  const dedupe =
    "kn_sv_" +
    location.hostname +
    "_" +
    (() => {
      try {
        return btoa(unescape(encodeURIComponent(uname + "\n" + password))).slice(0, 48);
      } catch (_) {
        return String(uname.length) + "_" + String(password.length);
      }
    })();
  try {
    const prev = sessionStorage.getItem(dedupe);
    if (prev && now - Number(prev) < 120000) return;
  } catch (_) {}

  let shouldPost = false;
  try {
    const q = new URL(BRIDGE);
    q.searchParams.set("url", location.href);
    const res = await fetch(q);
    if (res.ok) {
      const list = await res.json();
      const unameLower = uname.toLowerCase();
      const match = Array.isArray(list)
        ? list.find((x) => String(x.username || "").trim().toLowerCase() === unameLower)
        : null;
      if (match) {
        if (match.password === password) {
          shouldPost = false;
        } else {
          const mismatchAskKey =
            "kn_pwMismatchAsked_" +
            location.hostname +
            "_" +
            (() => {
              try {
                return btoa(unescape(encodeURIComponent(unameLower))).slice(0, 48);
              } catch (_) {
                return String(unameLower.length);
              }
            })();
          let alreadyAsked = false;
          try {
            alreadyAsked = !!sessionStorage.getItem(mismatchAskKey);
          } catch (_) {}
          if (alreadyAsked) {
            shouldPost = false;
          } else {
            shouldPost = confirm(
              "KeyNest 已保存该账号，但密码与当前输入不一致。\n\n是否用新密码更新保管库？"
            );
            try {
              sessionStorage.setItem(mismatchAskKey, String(Date.now()));
            } catch (_) {}
          }
        }
      } else {
        const msg = uname
          ? "是否将当前账号与密码保存到本机 KeyNest？"
          : "未检测到用户名（部分网站用手机号字段）。是否仍将密码保存到本机 KeyNest？可在桌面端再补充用户名。";
        shouldPost = confirm(msg);
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
    const pageUrl = payload.url || location.href;
    const limit = await fetchSiteLimitCheck(pageUrl, uname);
    if (!(await confirmSiteLimitIfNeeded(limit || {}))) return;

    try {
      sessionStorage.setItem(dedupe, String(now));
    } catch (_) {}
    fetch(SAVE_BRIDGE, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: payload.title || document.title || "",
        url: pageUrl,
        username: uname,
        password,
        confirmEvict: !!(limit && limit.needsConfirm),
      }),
      keepalive: true,
    }).catch(() => {});
  }
}

/** 页面内简短提示（不阻塞操作） */
function showKeynestHint(text) {
  document.getElementById(HINT_ID)?.remove();
  if (!text || !document.body) return;
  const wrap = document.createElement("div");
  wrap.id = HINT_ID;
  wrap.setAttribute("data-keynest", "1");
  const sh = wrap.attachShadow({ mode: "open" });
  const s = document.createElement("style");
  s.textContent = `
    .bar {
      position: fixed;
      left: 50%;
      bottom: 88px;
      transform: translateX(-50%);
      z-index: 2147483646;
      max-width: min(420px, calc(100vw - 32px));
      padding: 12px 16px;
      border-radius: 12px;
      background: rgba(15, 23, 42, 0.92);
      color: #f1f5f9;
      font: 13px/1.45 system-ui, -apple-system, sans-serif;
      box-shadow: 0 8px 24px rgba(0,0,0,.35);
      border: 1px solid rgba(255,255,255,.12);
    }
  `;
  const bar = document.createElement("div");
  bar.className = "bar";
  bar.textContent = text;
  sh.appendChild(s);
  sh.appendChild(bar);
  document.body.appendChild(wrap);
  setTimeout(() => wrap.remove(), 8000);
}

function isOurUiElement(el) {
  if (!(el instanceof Element)) return false;
  return Boolean(el.closest?.("[data-keynest]") || el.id === WRAP_ID || el.id === HINT_ID);
}

function looksLikeLoginButton(el) {
  if (!(el instanceof Element)) return false;
  if (isOurUiElement(el)) return false;
  let node = el;
  for (let i = 0; i < 8 && node; i++) {
    const tag = (node.tagName || "").toLowerCase();
    const role = (node.getAttribute?.("role") || "").toLowerCase();
    const text =
      (node.textContent || "") +
      " " +
      (node.getAttribute?.("aria-label") || "") +
      " " +
      (node.getAttribute?.("value") || "") +
      " " +
      (node.className || "") +
      " " +
      (node.id || "");
    if (/register|sign\s*up|forgot|reset\s+password|找回密码|免费注册/i.test(text)) return false;

    const isSubmitInput = tag === "input" && /^(submit|button)$/i.test(node.getAttribute("type") || "");
    const isTextButton =
      tag === "button" || role === "button" || isSubmitInput || tag === "a";
    if (!isTextButton) {
      node = node.parentElement;
      continue;
    }

    if (
      /sign\s*in|log\s*in|logon|login|submit|continu|next|verify|unlock|authorize|登\s*录|登陆|登录|进入|确认|提交|下一步|验证|开始|登\s*入/i.test(
        text
      )
    )
      return true;
    if (isSubmitInput) return true;
    node = node.parentElement;
  }
  return false;
}

/** 在站点改写密码框为密文之前同步抓取（登录按钮 mousedown/click 的 capture 阶段） */
function capturePendingSaveSnapshot() {
  const snapAll = globalThis.__keynestSnapshotPlainPasswords;
  if (typeof snapAll === "function") snapAll();
  const snapFn = globalThis.__keynestCollectLoginSnapshot;
  if (typeof snapFn !== "function") return;
  const snap = snapFn();
  if (!snap || !String(snap.password || "").trim()) return;
  globalThis.__keynestPendingSaveSnapshot = {
    username: snap.username || "",
    password: snap.password,
    capturedAt: Date.now(),
  };
}

function pickSaveSnapshot() {
  const pending = globalThis.__keynestPendingSaveSnapshot;
  const looksCipher = globalThis.__keynestLooksLikeSiteCiphertext;
  const snapFn = globalThis.__keynestCollectLoginSnapshot;

  if (pending && Date.now() - pending.capturedAt < 8000) {
    const pwd = String(pending.password || "").trim();
    if (pwd) {
      if (typeof snapFn === "function") {
        const fresh = snapFn();
        const freshPwd = fresh ? String(fresh.password || "").trim() : "";
        if (
          freshPwd &&
          typeof looksCipher === "function" &&
          looksCipher(freshPwd, pwd) &&
          !looksCipher(pwd, freshPwd)
        ) {
          return {
            username: pending.username || fresh?.username || "",
            password: pwd,
          };
        }
      }
      return { username: pending.username || "", password: pwd };
    }
  }

  if (typeof snapFn !== "function") return null;
  const snap = snapFn();
  if (!snap || !String(snap.password || "").trim()) return null;
  return { username: snap.username || "", password: snap.password };
}

function cancelScheduledSnapshotSave() {
  clearTimeout(globalThis.__keynestSaveDebounce);
  globalThis.__keynestSaveDebounce = null;
}

function scheduleSnapshotSave() {
  if (Date.now() - (globalThis.__knSaveOfferHandledAt || 0) < 2500) return;
  cancelScheduledSnapshotSave();
  globalThis.__keynestSaveDebounce = setTimeout(() => {
    if (Date.now() - (globalThis.__knSaveOfferHandledAt || 0) < 2500) return;
    const snap = pickSaveSnapshot();
    if (!snap) return;
    delete globalThis.__keynestPendingSaveSnapshot;
    if (!String(snap.username || "").trim()) {
      showKeynestHint(
        "KeyNest：未检测到账号输入框内容。若网站用手机号登录，请先填写手机号再点登录；也可之后在桌面端补充用户名。"
      );
    }
    runSaveOffer({
      title: document.title || "",
      url: location.href,
      username: snap.username || "",
      password: snap.password,
    });
  }, 320);
}

/** 点击是否会走经典 form submit（由 submit 监听统一弹窗，避免重复） */
function willTriggerFormSubmitFromClick(el) {
  const form = el.closest?.("form");
  if (!(form instanceof HTMLFormElement)) return false;
  if (!tpLooksLikeClassicPasswordLogin(form)) return false;
  let node = el;
  for (let i = 0; i < 8 && node; i++) {
    const tag = (node.tagName || "").toLowerCase();
    if (tag === "button") {
      const type = (node.getAttribute("type") || "submit").toLowerCase();
      return type === "submit" || type === "";
    }
    if (tag === "input" && (node.getAttribute("type") || "").toLowerCase() === "submit") return true;
    node = node.parentElement;
  }
  return false;
}

function onLoginSubmitIntent(ev) {
  const t = ev.target;
  if (!(t instanceof Element)) return;
  if (isOurUiElement(t)) return;
  if (!looksLikeLoginButton(t)) return;
  capturePendingSaveSnapshot();
  if (willTriggerFormSubmitFromClick(t)) return;
  scheduleSnapshotSave();
}

document.addEventListener("mousedown", onLoginSubmitIntent, true);

document.addEventListener(
  "keydown",
  (ev) => {
    if (ev.key !== "Enter" || ev.isComposing || ev.defaultPrevented) return;
    const t = ev.target;
    if (!(t instanceof HTMLElement)) return;
    if (t.isContentEditable) return;
    if (t instanceof HTMLTextAreaElement) return;
    if (t instanceof HTMLInputElement && t.type === "password") {
      capturePendingSaveSnapshot();
      scheduleSnapshotSave();
    }
  },
  true
);

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

    const snapAll = globalThis.__keynestSnapshotPlainPasswords;
    if (typeof snapAll === "function") snapAll();

    ev.preventDefault();

    const passwordEl = tpFindLoginPasswordInput(form);
    const usernameEl = tpFindUsernameInput(form, passwordEl);
    const resolver = globalThis.__keynestResolvePlainPassword;
    const password =
      typeof resolver === "function" ? resolver(passwordEl) : String(passwordEl.value || "");
    const username = String(usernameEl.value || "").trim();

    const payload = {
      title: document.title || "",
      url: location.href,
      username,
      password,
    };

    cancelScheduledSnapshotSave();
    globalThis.__knSaveOfferHandledAt = Date.now();
    await runSaveOffer(payload);

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
