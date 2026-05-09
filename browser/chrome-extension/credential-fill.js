/**
 * 与 React / Vue 等受控输入兼容：不能仅用 el.value = x；穿透 Shadow DOM；填入后校验 DOM。
 * 返回 Promise<{ ok, reason? }>，便于扩展 UI 区分「未生效」。
 */
(function () {
  "use strict";

  /**
   * @param {HTMLElement} el
   */
  function isVisible(el) {
    if (!el || !(el instanceof HTMLElement)) return false;
    const st = globalThis.getComputedStyle(el);
    if (st.visibility === "hidden" || st.display === "none") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  /**
   * @param {ParentNode} container
   * @param {string} selector
   * @returns {HTMLElement[]}
   */
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

  function findAllPasswordInputs() {
    return querySelectorAllDeep(document.documentElement, 'input[type="password"]').filter(
      (el) => el instanceof HTMLInputElement && isVisible(el)
    );
  }

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
      const area = r.width * r.height;
      score += Math.min(area / 100, 40);
      const cx = (r.left + r.right) / 2;
      const cy = (r.top + r.bottom) / 2;
      const vx = globalThis.innerWidth / 2;
      const vy = globalThis.innerHeight / 2;
      score -= (Math.abs(cx - vx) + Math.abs(cy - vy)) / 50;
      if (el.disabled || el.readOnly) score -= 30;
      return { el, score };
    });
    scored.sort((a, b) => b.score - a.score);
    return scored[0].el;
  }

  const USERNAME_TYPES = /^(email|text|tel|search|url|number)$/i;

  function isUsernameType(el) {
    const t = (el.getAttribute("type") || "text").toLowerCase();
    if (t === "hidden" || t === "password" || t === "checkbox" || t === "radio" || t === "button" || t === "submit" || t === "file" || t === "range" || t === "color") return false;
    if (!USERNAME_TYPES.test(t) && t !== "") return false;
    return true;
  }

  function semanticUsernameScore(el) {
    const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
    const blob =
      (el.getAttribute("aria-label") || "") +
      (el.getAttribute("placeholder") || "") +
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
      if (dy > 8 && dy < 360 && Math.abs(ecx - pcx) < Math.max(pr.width, r.width) * 2.5) {
        score += 40;
      }
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
    const others = passwords.filter((p) => p !== passEl);
    const scope =
      others.length > 0 ? document.documentElement : passEl.closest("main") || passEl.closest('[role="main"]') || document.body || document.documentElement;
    return findUsernameInContainer(scope, passEl);
  }

  function setNativeValue(el, value) {
    if (!el) return;

    const lastValue = el.value;

    const proto =
      el instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, "value");
    if (desc && typeof desc.set === "function") {
      desc.set.call(el, value);
    } else {
      el.value = value;
    }

    const tracker = el._valueTracker;
    if (tracker && typeof tracker.setValue === "function") {
      tracker.setValue(lastValue);
    }

    el.dispatchEvent(
      new InputEvent("input", {
        bubbles: true,
        cancelable: true,
        inputType: "insertFromPaste",
        data: value,
      })
    );
    el.dispatchEvent(new Event("change", { bubbles: true }));
    try {
      el.dispatchEvent(
        new InputEvent("beforeinput", {
          bubbles: true,
          cancelable: true,
          inputType: "insertFromPaste",
          data: value,
        })
      );
    } catch (_) {}
  }

  /**
   * @param {HTMLInputElement | HTMLTextAreaElement} el
   * @param {string} value
   */
  function tryInsertTextCommand(el, value) {
    if (!el || value == null) return false;
    try {
      el.focus({ preventScroll: true });
      if (typeof el.select === "function") el.select();
      if (document.execCommand && document.execCommand("insertText", false, value)) {
        el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertFromPaste", data: value }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      }
    } catch (_) {}
    return false;
  }

  /**
   * @param {HTMLInputElement | null} passEl
   * @param {HTMLInputElement | HTMLTextAreaElement | null} userEl
   * @param {{ username?: string, password?: string }} cred
   */
  function verifyCredFilled(passEl, userEl, cred) {
    const wantPass = cred.password != null ? String(cred.password) : "";
    const wantUser = cred.username != null ? String(cred.username) : "";
    if (wantPass && (!passEl || String(passEl.value) !== wantPass)) return false;
    if (wantUser !== "" && (!userEl || String(userEl.value) !== wantUser)) return false;
    return true;
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  /**
   * @param {{ username?: string, password?: string }} cred
   */
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
        setTimeout(fillPass, userEl && cred.username != null && cred.username !== "" ? 28 : 0);
      }
    };

    const applyPasteFallback = () => {
      const passEl = pickBestPasswordInput();
      const userEl = passEl ? findUsernameForPassword(passEl) : null;
      if (cred.password != null && passEl && String(passEl.value) !== String(cred.password)) {
        tryInsertTextCommand(passEl, String(cred.password));
      }
      if (cred.username != null && cred.username !== "" && userEl && String(userEl.value) !== String(cred.username)) {
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
        if (verifyCredFilled(passEl, userEl, cred)) {
          return { ok: true };
        }
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

  /**
   * 供 content 脚本在登录「按钮点击」等非经典 submit 场景读取当前输入框（含 Shadow DOM）。
   * @returns {{ username: string, password: string } | null}
   */
  function collectLoginSnapshot() {
    const passEl = pickBestPasswordInput();
    if (!passEl || !String(passEl.value || "").trim()) return null;
    const userEl = findUsernameForPassword(passEl);
    let username = userEl ? String(userEl.value || "").trim() : "";
    if (!username) {
      const passwords = findAllPasswordInputs();
      const scope =
        passwords.length > 1
          ? document.documentElement
          : passEl.closest("main") || passEl.closest('[role="main"]') || document.body || document.documentElement;
      const telCandidates = querySelectorAllDeep(scope, 'input[type="tel"]').filter(
        (el) => el instanceof HTMLInputElement && isVisible(el) && el !== passEl
      );
      const tel = telCandidates.find((el) => String(el.value || "").trim());
      if (tel) username = String(tel.value || "").trim();
    }
    return {
      username,
      password: String(passEl.value || ""),
    };
  }

  globalThis.__keynestFillCredentials = fillCredentials;
  globalThis.__keynestCollectLoginSnapshot = collectLoginSnapshot;
})();
