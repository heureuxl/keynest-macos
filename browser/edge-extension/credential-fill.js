/**
 * 与 React / Vue 等受控输入兼容：不能仅用 el.value = x；穿透 Shadow DOM；填入后校验 DOM。
 * 密码明文：从 DOM、输入事件累积、元素/表单上下文合并，避免掩码单字符与提交后密文。
 */
(function () {
  "use strict";

  function isVisible(el) {
    if (!el || !(el instanceof HTMLElement)) return false;
    const st = globalThis.getComputedStyle(el);
    if (st.visibility === "hidden" || st.display === "none") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function querySelectorAllDeep(container, selector) {
    const out = /** @type {HTMLElement[]} */ ([]);
    function walk(subroot) {
      if (!subroot || !subroot.querySelectorAll) return;
      try {
        subroot.querySelectorAll(selector).forEach((el) => {
          if (el instanceof HTMLElement) out.push(el);
        });
      } catch (_) {}
      subroot.querySelectorAll("*").forEach((el) => {
        if (el.shadowRoot) walk(el.shadowRoot);
      });
    }
    walk(container);
    return out;
  }

  const plainPasswordMemo = new WeakMap();
  const plainPasswordByContext = new Map();
  const typedPasswordByKey = new WeakMap();
  const keydownHandledAt = new WeakMap();
  const MAX_CONTEXT_ENTRIES = 12;

  function isPasswordField(el) {
    const fn = globalThis.__keynestIsPasswordLikeInput;
    if (typeof fn === "function") return fn(el);
    return el instanceof HTMLInputElement && el.type === "password";
  }

  function appendTypedPlain(el, chunk, replace) {
    if (!isPasswordField(el)) return;
    let buf = replace ? String(chunk ?? "") : (typedPasswordByKey.get(el) || "") + String(chunk ?? "");
    typedPasswordByKey.set(el, buf);
    if (buf.length >= 2) mergePlainIntoStores(el, buf);
  }

  function getPasswordContextKey(el) {
    const form = el.closest("form");
    const formKey = form
      ? String(form.id || form.name || form.getAttribute("action") || "").slice(0, 160)
      : "";
    return `${location.pathname}\n${formKey}`;
  }

  function pruneContextMap() {
    while (plainPasswordByContext.size > MAX_CONTEXT_ENTRIES) {
      const first = plainPasswordByContext.keys().next().value;
      if (first === undefined) break;
      plainPasswordByContext.delete(first);
    }
  }

  const pickBetterPlain =
    globalThis.__keynestPickBetterPlain ||
    function (prev, next) {
      if (!next) return prev ?? "";
      if (!prev) return next;
      return next.length >= prev.length ? next : prev;
    };

  function mergePlainIntoStores(el, plain) {
    if (!plain || !(el instanceof HTMLInputElement) || !isPasswordField(el)) return;
    const p = String(plain);
    if (p.length === 1) return;
    typedPasswordByKey.set(el, pickBetterPlain(typedPasswordByKey.get(el), p));
    plainPasswordMemo.set(el, pickBetterPlain(plainPasswordMemo.get(el), p));
    const ctxKey = getPasswordContextKey(el);
    plainPasswordByContext.set(ctxKey, pickBetterPlain(plainPasswordByContext.get(ctxKey), p));
    pruneContextMap();
    const rec = globalThis.__keynestRecordTruePlain;
    if (typeof rec === "function") rec(el, p);
    else {
      const pub = globalThis.__keynestPublishPageCredential;
      if (typeof pub === "function") pub(p, "");
    }
  }

  function applyInputEventToTypedBuffer(ev) {
    const t = ev.target;
    if (!isPasswordField(t)) return;
    const inputType = String(ev.inputType || "");
    let buf = typedPasswordByKey.get(t) || "";

    if (inputType === "deleteContentBackward" || inputType === "deleteWordBackward") {
      buf = buf.slice(0, Math.max(0, buf.length - 1));
    } else if (inputType === "deleteContentForward") {
      buf = buf.slice(1);
    } else if (inputType === "deleteByCut") {
      buf = String(t.value ?? "") ? buf.slice(0, Math.max(0, buf.length - 1)) : "";
    } else if (
      inputType === "insertText" ||
      inputType === "insertCompositionText" ||
      inputType === "insertFromPaste" ||
      inputType === "insertFromDrop" ||
      inputType === "insertReplacementText" ||
      inputType === "insertFromYank"
    ) {
      const data = ev.data;
      if (data != null && data !== "") {
        buf =
          inputType === "insertFromPaste" || inputType === "insertReplacementText"
            ? data
            : buf + data;
      }
    }

    if (buf.length >= 2) mergePlainIntoStores(t, buf);
    else if (buf.length === 1) typedPasswordByKey.set(t, buf);
  }

  function findHiddenPasswordValues() {
    const out = [];
    for (const el of querySelectorAllDeep(document.documentElement, 'input[type="hidden"]')) {
      if (!(el instanceof HTMLInputElement)) continue;
      const blob = (el.name || "") + (el.id || "") + (el.getAttribute("autocomplete") || "");
      if (!/pass|pwd|密码/i.test(blob)) continue;
      const v = String(el.value || "").trim();
      if (v.length >= 2) out.push(v);
    }
    return out;
  }

  function findAllPasswordInputs() {
    const pass = querySelectorAllDeep(document.documentElement, 'input[type="password"]').filter(
      (el) => el instanceof HTMLInputElement && isVisible(el)
    );
    const textLike = querySelectorAllDeep(
      document.documentElement,
      'input[type="text"], input[type="tel"], input:not([type])'
    ).filter((el) => el instanceof HTMLInputElement && isVisible(el) && isPasswordField(el));
    const seen = new Set(pass);
    for (const el of textLike) {
      if (!seen.has(el)) {
        pass.push(el);
        seen.add(el);
      }
    }
    return pass;
  }

  function bestPlainPassword(passwordEl) {
    if (!(passwordEl instanceof HTMLInputElement)) {
      return String(passwordEl?.value ?? "").trim();
    }
    if (!isPasswordField(passwordEl)) {
      return String(passwordEl.value ?? "").trim();
    }
    const topSt = globalThis.__keynestKnTopState?.();
    const hooked = globalThis.__keynestGetHookedPlain?.(passwordEl) || "";
    const typed = typedPasswordByKey.get(passwordEl) || "";
    const memo = plainPasswordMemo.get(passwordEl) || "";
    const ctx = plainPasswordByContext.get(getPasswordContextKey(passwordEl)) || "";
    const domVal = String(passwordEl.value ?? "").trim();
    const parts = [topSt?.pagePassword, hooked, typed, memo, ctx, ...findHiddenPasswordValues()];
    const looksCipher = globalThis.__keynestLooksLikeSiteCiphertext;
    if (
      domVal.length >= 2 &&
      (typeof looksCipher !== "function" || !looksCipher(domVal, typed || memo || ctx || ""))
    ) {
      parts.push(domVal);
    }
    const fold = globalThis.__keynestBestPlainFromSources;
    return typeof fold === "function" ? fold(parts) : "";
  }

  function snapshotAllPlainPasswords() {
    try {
      for (const el of findAllPasswordInputs()) {
        const best = bestPlainPassword(el);
        if (best) mergePlainIntoStores(el, best);
      }
    } catch (_) {}
  }

  function resolvePlainPassword(passwordEl) {
    return bestPlainPassword(passwordEl);
  }

  function bindPasswordMemoryEvents() {
    document.addEventListener(
      "beforeinput",
      (ev) => {
        const t = ev.target;
        if (!isPasswordField(t)) return;
        const it = String(ev.inputType || "");
        if (
          it.startsWith("delete") ||
          it === "insertFromPaste" ||
          it === "insertReplacementText" ||
          it === "insertFromDrop" ||
          it === "insertFromYank"
        ) {
          applyInputEventToTypedBuffer(ev);
        }
      },
      true
    );
    document.addEventListener(
      "keydown",
      (ev) => {
        if (ev.isComposing || ev.repeat || ev.ctrlKey || ev.metaKey || ev.altKey) return;
        const t = ev.target;
        if (!isPasswordField(t)) return;
        const key = ev.key;
        let buf = typedPasswordByKey.get(t) || "";
        if (key === "Backspace") {
          appendTypedPlain(t, buf.slice(0, Math.max(0, buf.length - 1)), true);
          return;
        }
        if (key === "Delete") {
          appendTypedPlain(t, buf.slice(1), true);
          return;
        }
        if (key.length !== 1) return;
        keydownHandledAt.set(t, Date.now());
        appendTypedPlain(t, buf + key, true);
      },
      true
    );
    document.addEventListener(
      "focusout",
      (ev) => {
        if (!isPasswordField(ev.target)) return;
        const best = bestPlainPassword(ev.target);
        if (best) mergePlainIntoStores(ev.target, best);
        armSaveCapture();
      },
      true
    );
    document.addEventListener("pointerdown", snapshotAllPlainPasswords, true);
  }

  bindPasswordMemoryEvents();

  function armSaveCapture() {
    snapshotAllPlainPasswords();
    const snap = collectLoginSnapshot();
    if (!snap?.password) return false;
    const merge = globalThis.__keynestMergeArmedCredential;
    return (
      typeof merge === "function" &&
      merge(snap.username, snap.password, { title: document.title, url: location.href })
    );
  }

  globalThis.__keynestResolvePlainPassword = resolvePlainPassword;
  globalThis.__keynestBestPlainPassword = bestPlainPassword;
  globalThis.__keynestSnapshotPlainPasswords = snapshotAllPlainPasswords;
  globalThis.__keynestArmSaveCapture = armSaveCapture;

  function pickBestPasswordInput() {
    const list = findAllPasswordInputs();
    if (!list.length) return null;
    if (list.length === 1) return list[0];

    const scored = list.map((el) => {
      const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
      let score = 0;
      if (ac.includes("current-password")) score += 100;
      if (ac.includes("new-password")) score -= 50;
      const r = el.getBoundingClientRect();
      score += Math.min((r.width * r.height) / 100, 40);
      const cx = (r.left + r.right) / 2;
      const cy = (r.top + r.bottom) / 2;
      score -= (Math.abs(cx - globalThis.innerWidth / 2) + Math.abs(cy - globalThis.innerHeight / 2)) / 50;
      if (el.disabled || el.readOnly) score -= 30;
      score += bestPlainPassword(el).length;
      return { el, score };
    });
    scored.sort((a, b) => b.score - a.score);
    return scored[0].el;
  }

  const USERNAME_TYPES = /^(email|text|tel|search|url|number)$/i;

  function isUsernameType(el) {
    const t = (el.getAttribute("type") || "text").toLowerCase();
    if (
      t === "hidden" ||
      t === "password" ||
      t === "checkbox" ||
      t === "radio" ||
      t === "button" ||
      t === "submit" ||
      t === "file" ||
      t === "range" ||
      t === "color"
    ) {
      return false;
    }
    return USERNAME_TYPES.test(t) || t === "";
  }

  function semanticUsernameScore(el) {
    const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
    const blob =
      (el.getAttribute("aria-label") || "") +
      (el.placeholder || "") +
      (el.name || "") +
      (el.id || "") +
      ac +
      (el.getAttribute("data-testid") || "");
    let s = 0;
    if (/^(username|email|tel)$/i.test(ac) || ac.includes("nickname")) s += 80;
    if (/user|login|mail|account|phone|acct|id|email|手机|账号|邮箱|用户名|登陆|登录/i.test(blob)) s += 25;
    if (el.type === "email") s += 15;
    if (el.type === "search" && !/user|login|mail|account|手机|账号|邮箱/i.test(blob)) s -= 40;
    return s;
  }

  function findUsernameInContainer(container, passEl) {
    const candidates = /** @type {(HTMLInputElement | HTMLTextAreaElement)[]} */ ([]);
    const inputs = querySelectorAllDeep(container, "input, textarea");
    for (const el of inputs) {
      if (!(el instanceof HTMLInputElement) && !(el instanceof HTMLTextAreaElement)) continue;
      if (el === passEl) continue;
      if (!isVisible(el)) continue;
      if (el instanceof HTMLInputElement && !isUsernameType(el)) continue;
      if (el instanceof HTMLInputElement) {
        const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
        if (ac.includes("current-password") || ac.includes("new-password")) continue;
      }
      candidates.push(el);
    }
    if (!candidates.length) return null;

    const pr = passEl.getBoundingClientRect();
    const pcx = (pr.left + pr.right) / 2;
    const pcy = (pr.top + pr.bottom) / 2;

    let best = null;
    let bestScore = -Infinity;
    for (const el of candidates) {
      let score = semanticUsernameScore(el);
      const r = el.getBoundingClientRect();
      const ecx = (r.left + r.right) / 2;
      const ecy = (r.top + r.bottom) / 2;
      const dy = pcy - ecy;
      if (dy > 8 && dy < 360 && Math.abs(ecx - pcx) < Math.max(pr.width, r.width) * 2.5) score += 40;
      if (r.bottom <= pr.top + 4) score += 20;
      if (score > bestScore) {
        bestScore = score;
        best = el;
      }
    }
    return best;
  }

  function findUsernameForPassword(passEl) {
    const form = passEl.closest("form");
    if (form) {
      const u = findUsernameInContainer(form, passEl);
      if (u) return u;
    }
    let container = passEl.parentElement;
    for (let i = 0; i < 8 && container; i++) {
      const u = findUsernameInContainer(container, passEl);
      if (u) return u;
      container = container.parentElement;
    }
    const passwords = findAllPasswordInputs();
    const scope =
      passwords.length > 1
        ? document.documentElement
        : passEl.closest("main") || passEl.closest('[role="main"]') || document.body || document.documentElement;
    return findUsernameInContainer(scope, passEl);
  }

  function setNativeValue(el, value) {
    if (!el) return;
    const lastValue = el.value;
    const proto =
      el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, "value");
    if (desc && typeof desc.set === "function") desc.set.call(el, value);
    else el.value = value;

    const tracker = el._valueTracker;
    if (tracker && typeof tracker.setValue === "function") tracker.setValue(lastValue);

    el.dispatchEvent(
      new InputEvent("input", {
        bubbles: true,
        cancelable: true,
        inputType: "insertFromPaste",
        data: value,
      })
    );
    el.dispatchEvent(new Event("change", { bubbles: true }));
    if (el instanceof HTMLInputElement && isPasswordField(el) && value) {
      mergePlainIntoStores(el, String(value));
    }
  }

  function tryInsertTextCommand(el, value) {
    if (!el || value == null) return false;
    try {
      el.focus({ preventScroll: true });
      if (typeof el.select === "function") el.select();
      if (document.execCommand && document.execCommand("insertText", false, value)) {
        el.dispatchEvent(
          new InputEvent("input", { bubbles: true, inputType: "insertFromPaste", data: value })
        );
        el.dispatchEvent(new Event("change", { bubbles: true }));
        if (el instanceof HTMLInputElement && isPasswordField(el)) {
          mergePlainIntoStores(el, String(value));
        }
        return true;
      }
    } catch (_) {}
    return false;
  }

  function verifyCredFilled(passEl, userEl, cred) {
    const wantPass = cred.password != null ? String(cred.password) : "";
    const wantUser = cred.username != null ? String(cred.username) : "";
    if (wantPass) {
      const got = passEl ? bestPlainPassword(passEl) : "";
      if (got !== wantPass && String(passEl?.value ?? "") !== wantPass) return false;
    }
    if (wantUser !== "" && (!userEl || String(userEl.value) !== wantUser)) return false;
    return true;
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function fillCredentials(cred) {
    if (!cred) return { ok: false, reason: "" };

    const applyValues = () => {
      const passEl = pickBestPasswordInput();
      if (!passEl) return;
      const userEl = findUsernameForPassword(passEl);
      if (userEl && cred.username != null && cred.username !== "") {
        userEl.focus({ preventScroll: true });
        setNativeValue(userEl, cred.username);
      }
      const fillPass = () => {
        const p = pickBestPasswordInput();
        if (p && cred.password != null) {
          p.focus({ preventScroll: true });
          setNativeValue(p, cred.password);
        }
      };
      if (cred.password != null) {
        setTimeout(fillPass, userEl && cred.username ? 28 : 0);
      }
    };

    const applyPasteFallback = () => {
      const passEl = pickBestPasswordInput();
      const userEl = passEl ? findUsernameForPassword(passEl) : null;
      if (cred.password != null && passEl && bestPlainPassword(passEl) !== String(cred.password)) {
        tryInsertTextCommand(passEl, String(cred.password));
      }
      if (cred.username && userEl && String(userEl.value) !== String(cred.username)) {
        tryInsertTextCommand(userEl, String(cred.username));
      }
    };

    for (let round = 0; round < 4; round++) {
      applyValues();
      await sleep(35);
      applyPasteFallback();
      for (let step = 0; step < 18; step++) {
        await sleep(42);
        const passEl = pickBestPasswordInput();
        const userEl = passEl ? findUsernameForPassword(passEl) : null;
        if (verifyCredFilled(passEl, userEl, cred)) return { ok: true };
        if (step === 6 || step === 12) {
          applyValues();
          applyPasteFallback();
        }
      }
    }

    return {
      ok: false,
      reason: "页面未保留填入内容（可能被站点脚本清空）。请手动复制密码或使用右上角扩展图标重试。",
    };
  }

  function collectLoginSnapshot() {
    const passEl = pickBestPasswordInput();
    if (!passEl) return null;
    const localPass = bestPlainPassword(passEl);
    const topSt = globalThis.__keynestKnTopState?.();
    const fold = globalThis.__keynestBestPlainFromSources;
    const password =
      typeof fold === "function"
        ? fold([topSt?.pagePassword, localPass])
        : pickBetterPlain(topSt?.pagePassword || "", localPass);
    const saveable = globalThis.__keynestIsSaveablePassword;
    if (!password || (typeof saveable === "function" && !saveable(password))) return null;

    const userEl = findUsernameForPassword(passEl);
    let username = userEl ? String(userEl.value || "").trim() : "";
    if (!username && topSt?.pageUsername) username = String(topSt.pageUsername).trim();
    if (!username) {
      const scope =
        findAllPasswordInputs().length > 1
          ? document.documentElement
          : passEl.closest("main") || passEl.closest('[role="main"]') || document.body || document.documentElement;
      const tel = querySelectorAllDeep(scope, 'input[type="tel"]').find(
        (el) => el instanceof HTMLInputElement && isVisible(el) && String(el.value || "").trim()
      );
      if (tel) username = String(tel.value || "").trim();
    }
    const pub = globalThis.__keynestPublishPageCredential;
    if (typeof pub === "function") pub(password, username);
    return { username, password };
  }

  globalThis.__keynestFillCredentials = fillCredentials;
  globalThis.__keynestCollectLoginSnapshot = collectLoginSnapshot;
})();
