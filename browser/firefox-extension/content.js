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
  const max =
    typeof limit.maxAccounts === "number" && limit.maxAccounts > 0
      ? limit.maxAccounts
      : null;
  const count =
    typeof limit.currentCount === "number" && limit.currentCount >= 0
      ? limit.currentCount
      : null;
  if (max == null) {
    return (
      `网站「${site}」该站点账号数已达上限。\n\n` +
      `继续保存将移除最早条目。是否继续保存？`
    );
  }
  const incoming = String(limit.incomingUsername || "").trim() || "（无用户名）";
  const evictTitle = limit.evictTitle || "未命名";
  const evictUser = String(limit.evictUsername || "").trim() || "（无用户名）";
  return (
    `网站「${site}」已保存 ${count ?? "?"} 个不同账号（上限 ${max} 个）。\n\n` +
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

/** 跨 iframe 共享状态（manifest all_frames 时各帧 globalThis 独立） */
function knTopWindow() {
  try {
    return window.top;
  } catch (_) {
    return window;
  }
}

function knCoord() {
  const w = knTopWindow();
  if (!w.__knCoord) w.__knCoord = {};
  return w.__knCoord;
}

/** @param {{ title?: string, url: string, username: string, password: string }} payload */
async function runSaveOffer(payload) {
  const coord = knCoord();
  if (coord.saveOfferRunning) return;
  coord.saveOfferRunning = true;
  try {
    await runSaveOfferInner(payload);
  } finally {
    coord.saveOfferRunning = false;
  }
}

function isTopFrame() {
  try {
    return window === window.top;
  } catch (_) {
    return true;
  }
}

/** 保管库密码与待保存明文是否不同 */
function vaultPasswordDiffers(stored, typed) {
  if (stored === typed) return false;
  if (stored.length <= 2 && typed.length > stored.length) return true;
  const looksCipher = globalThis.__keynestLooksLikeSiteCiphertext;
  if (typeof looksCipher === "function") {
    if (looksCipher(typed, stored) || looksCipher(stored, typed)) return true;
  }
  return stored !== typed;
}

/** 任意帧捕获凭据；仅顶层帧弹出保存确认 */
function scheduleSaveOffer(delayMs) {
  const snap = globalThis.__keynestSnapshotPlainPasswords;
  if (typeof snap === "function") snap();
  const arm = globalThis.__keynestArmSaveCapture;
  if (typeof arm === "function") arm();

  const saveable = globalThis.__keynestIsSaveablePassword;
  const getArmed = globalThis.__keynestGetArmedCredential;
  const cred = typeof getArmed === "function" ? getArmed() : null;
  if (!cred?.password || (typeof saveable === "function" && !saveable(cred.password))) {
    return;
  }

  const top = knTopWindow();
  const delay = delayMs ?? 500;

  if (!isTopFrame()) {
    try {
      const snapFn = globalThis.__keynestCollectLoginSnapshot;
      const snap = typeof snapFn === "function" ? snapFn() : null;
      top.postMessage({ type: "keynest-schedule-save", delayMs: delay, cred: snap }, "*");
    } catch (_) {}
    return;
  }

  const st = globalThis.__keynestKnTopState?.();
  if (!st) return;
  clearTimeout(st.saveTimer);
  st.saveTimer = setTimeout(() => flushSaveOffer(), delay);
}

async function flushSaveOffer() {
  if (!isTopFrame()) return;

  const coord = knCoord();
  if (coord.saveOfferRunning) return;

  const getArmed = globalThis.__keynestGetArmedCredential;
  const saveable = globalThis.__keynestIsSaveablePassword;
  const cred = typeof getArmed === "function" ? getArmed() : null;
  if (!cred?.password || (typeof saveable === "function" && !saveable(cred.password))) {
    return;
  }

  await runSaveOffer({
    title: cred.title || document.title || "",
    url: cred.url || location.href,
    username: cred.username || "",
    password: cred.password,
  });
}

/** @returns {Promise<{ ok: boolean, hint?: string }>} */
async function postSaveToBridge(body, dedupeKey, now) {
  try {
    const res = await fetch(SAVE_BRIDGE, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    let data = {};
    try {
      data = await res.json();
    } catch (_) {}
    if (!res.ok) {
      const err = data.error || `HTTP ${res.status}`;
      return { ok: false, hint: `KeyNest：保存失败（${err}）。请确认桌面端已解锁并开启桥接。` };
    }
    if (data.cancelled === true || data.ok === false) {
      return { ok: false, hint: "KeyNest：保存已取消或遭拒绝（站点账号上限等）。" };
    }
    try {
      sessionStorage.setItem(dedupeKey, String(now));
    } catch (_) {}
    if (data.unchanged === true) {
      return { ok: true, hint: "KeyNest：该账号密码与保管库一致，无需更新。" };
    }
    return { ok: true };
  } catch (_) {
    return { ok: false, hint: "KeyNest：无法连接本机应用，请确认 KeyNest 已运行、已解锁并开启桥接。" };
  }
}

/** @param {{ title?: string, url: string, username: string, password: string }} payload */
async function runSaveOfferInner(payload) {
  const getArmed = globalThis.__keynestGetArmedCredential;
  const armed = typeof getArmed === "function" ? getArmed() : null;
  const pickBetter = globalThis.__keynestPickBetterPlain;

  const fold = globalThis.__keynestBestPlainFromSources;
  const pagePwd = globalThis.__keynestKnTopState?.()?.pagePassword || "";
  let password =
    typeof fold === "function"
      ? fold([pagePwd, armed?.password, payload.password])
      : String(payload.password || "").trim();
  let username = String(payload.username || armed?.username || "").trim();
  const saveable = globalThis.__keynestIsSaveablePassword;
  if (typeof saveable === "function" ? !saveable(password) : password.length < 2) {
    return;
  }

  const coord = knCoord();
  const now = Date.now();
  if (now - (coord.lastSaveOfferAt || 0) < 800) return;
  coord.lastSaveOfferAt = now;

  const uname = username;
  const dedupe =
    "kn_sv_ok_" +
    location.hostname +
    "_" +
    (() => {
      try {
        return btoa(unescape(encodeURIComponent(uname + "\n" + password))).slice(0, 48);
      } catch (_) {
        return String(uname.length) + "_" + String(password.length);
      }
    })();

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
        if (!vaultPasswordDiffers(match.password, password)) {
          shouldPost = false;
        } else {
          const looksCipher = globalThis.__keynestLooksLikeSiteCiphertext;
          const badVault =
            typeof looksCipher === "function" && looksCipher(match.password, password);
          if (badVault) {
            shouldPost = confirm(
              "KeyNest 中该账号保存的密码可能不是明文（曾被站点加密）。\n\n是否用当前输入的密码更新保管库？"
            );
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
          let declinedRecently = false;
          try {
            const declinedAt = sessionStorage.getItem(mismatchAskKey);
            if (declinedAt && Date.now() - Number(declinedAt) < 30 * 60 * 1000) {
              declinedRecently = true;
            }
          } catch (_) {}
          if (declinedRecently) {
            shouldPost = false;
          } else {
            shouldPost = confirm(
              "KeyNest 已保存该账号，但密码与当前输入不一致。\n\n是否用新密码更新保管库？"
            );
            try {
              if (shouldPost) sessionStorage.removeItem(mismatchAskKey);
              else sessionStorage.setItem(mismatchAskKey, String(Date.now()));
            } catch (_) {}
          }
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

    if (typeof saveable === "function" ? !saveable(password) : password.length < 2) {
      return;
    }

    const result = await postSaveToBridge(
      {
        title: payload.title || document.title || "",
        url: pageUrl,
        username: uname,
        password,
        confirmEvict: !!(limit && limit.needsConfirm),
      },
      dedupe,
      now
    );
    if (!result.ok && result.hint) {
      showKeynestHint(result.hint);
    } else if (result.ok) {
      const clear = globalThis.__keynestClearArmedCredential;
      if (typeof clear === "function") clear();
      if (result.hint) showKeynestHint(result.hint);
    }
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

function onLoginSubmitIntent(ev) {
  const t = ev.target;
  if (!(t instanceof Element)) return;
  if (isOurUiElement(t)) return;
  if (!looksLikeLoginButton(t)) return;
  scheduleSaveOffer(500);
}

document.addEventListener("pointerdown", onLoginSubmitIntent, true);

document.addEventListener(
  "keydown",
  (ev) => {
    if (ev.key !== "Enter" || ev.isComposing || ev.defaultPrevented) return;
    const t = ev.target;
    if (!(t instanceof HTMLElement)) return;
    if (t.isContentEditable) return;
    if (t instanceof HTMLTextAreaElement) return;
    if (t instanceof HTMLInputElement && (t.type === "password" || t.type === "text")) {
      scheduleSaveOffer(500);
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

function tpFormHasLoginPassword(form) {
  const pw = tpFindLoginPasswordInput(form);
  if (!pw) return false;
  const bestPlain = globalThis.__keynestBestPlainPassword;
  const plain =
    typeof bestPlain === "function"
      ? String(bestPlain(pw) || "").trim()
      : String(pw.value || "").trim();
  return plain.length > 0;
}

document.addEventListener(
  "submit",
  (ev) => {
    const form = ev.target;
    if (!(form instanceof HTMLFormElement)) return;
    if (!tpFormHasLoginPassword(form)) return;
    knCoord().saveOfferHandledAt = Date.now();
    scheduleSaveOffer(450);
  },
  true
);

if (isTopFrame()) {
  window.addEventListener("message", (ev) => {
    if (ev.source == null || ev.data?.type !== "keynest-schedule-save") return;
    const cred = ev.data.cred;
    const merge = globalThis.__keynestMergeArmedCredential;
    if (cred?.password && typeof merge === "function") {
      merge(cred.username, cred.password, {
        title: cred.title || document.title,
        url: cred.url || location.href,
      });
    } else {
      const arm = globalThis.__keynestArmSaveCapture;
      if (typeof arm === "function") arm();
    }
    const st = globalThis.__keynestKnTopState?.();
    if (!st) return;
    clearTimeout(st.saveTimer);
    st.saveTimer = setTimeout(() => flushSaveOffer(), ev.data.delayMs ?? 500);
  });
}

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
