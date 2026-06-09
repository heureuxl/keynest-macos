/**
 * KeyNest 跨 iframe 密码汇总。规则：无 ≥2 字符来源时返回空；单字符掩码永不入库。
 */
(function () {
  "use strict";

  const MIN_SAVE_PASSWORD_LEN = 2;

  function knTopWin() {
    try {
      return window.top;
    } catch (_) {
      return window;
    }
  }

  function knTopState() {
    const w = knTopWin();
    if (!w.__keynestTopState) {
      w.__keynestTopState = {
        pagePassword: "",
        pageUsername: "",
        armed: null,
        saveTimer: null,
      };
    }
    return w.__keynestTopState;
  }

  function looksLikeSiteCiphertext(domVal, plainHint) {
    if (!domVal || !plainHint || domVal === plainHint) return false;
    const dr = domVal.length;
    const rr = plainHint.length;
    if (rr < 2) return false;
    if (dr < 2) return false;
    const c = domVal.replace(/\s/g, "");
    if (dr >= rr * 1.5 && dr >= rr + 12) return true;
    if (dr >= rr * 2) return true;
    if (dr >= rr + 16 && dr >= 24) return true;
    if (dr >= 32 && /^[0-9a-f]{32,}$/i.test(c)) return true;
    if (dr >= 36 && rr <= 128 && /^[A-Za-z0-9+/=_-]+$/.test(c)) return true;
    return false;
  }

  function pickBetterPlain(prev, next) {
    if (!next) return prev ?? "";
    if (!prev) return next;
    if (next === prev) return prev;
    if (looksLikeSiteCiphertext(next, prev)) return prev;
    if (looksLikeSiteCiphertext(prev, next)) return next;
    if (next.length === 1 && prev.length >= 2) return prev;
    if (prev.length === 1 && next.length >= 2) return next;
    if (next.length > prev.length) return next;
    if (next.length < prev.length) return prev;
    return next;
  }

  /** 仅当存在长度≥2 的候选时才返回最佳明文；否则 "" */
  function bestPlainFromSources(sources) {
    const list = [];
    for (const s of sources) {
      const t = s != null ? String(s).trim() : "";
      if (t) list.push(t);
    }
    const longOnes = list.filter((s) => s.length >= MIN_SAVE_PASSWORD_LEN);
    if (!longOnes.length) return "";
    let best = "";
    for (const s of longOnes) best = pickBetterPlain(best, s);
    return best.length >= MIN_SAVE_PASSWORD_LEN ? best : "";
  }

  function isSaveablePassword(password) {
    return String(password ?? "").trim().length >= MIN_SAVE_PASSWORD_LEN;
  }

  function publishPageCredential(password, username) {
    const st = knTopState();
    const pwd = password != null ? String(password).trim() : "";
    if (isSaveablePassword(pwd)) {
      st.pagePassword = pickBetterPlain(st.pagePassword || "", pwd);
    }
    if (username) st.pageUsername = String(username).trim() || st.pageUsername;
  }

  function mergeArmedCredential(username, password, meta) {
    const st = knTopState();
    const pwd = bestPlainFromSources([st.pagePassword, st.armed?.password, password]);
    if (!isSaveablePassword(pwd)) return false;
    const user = String(username || st.armed?.username || st.pageUsername || "").trim();
    st.armed = {
      username: user,
      password: pwd,
      title: meta?.title ?? st.armed?.title ?? document.title ?? "",
      url: meta?.url ?? st.armed?.url ?? location.href,
      capturedAt: Date.now(),
    };
    publishPageCredential(pwd, user);
    return true;
  }

  function getArmedCredential(maxAgeMs) {
    const st = knTopState();
    const pwd = bestPlainFromSources([st.pagePassword, st.armed?.password]);
    if (!isSaveablePassword(pwd)) return null;
    if (st.armed && Date.now() - st.armed.capturedAt > (maxAgeMs ?? 120000)) {
      if (!isSaveablePassword(st.pagePassword)) return null;
    }
    return {
      username: String(st.armed?.username || st.pageUsername || "").trim(),
      password: pwd,
      title: st.armed?.title || "",
      url: st.armed?.url || location.href,
    };
  }

  function clearArmedCredential() {
    knTopState().armed = null;
  }

  globalThis.__keynestKnTopState = knTopState;
  globalThis.__keynestPublishPageCredential = publishPageCredential;
  globalThis.__keynestMergeArmedCredential = mergeArmedCredential;
  globalThis.__keynestGetArmedCredential = getArmedCredential;
  globalThis.__keynestClearArmedCredential = clearArmedCredential;
  globalThis.__keynestPickBetterPlain = pickBetterPlain;
  globalThis.__keynestBestPlainFromSources = bestPlainFromSources;
  globalThis.__keynestLooksLikeSiteCiphertext = looksLikeSiteCiphertext;
  globalThis.__keynestIsSaveablePassword = isSaveablePassword;
  globalThis.__keynestMinSavePasswordLen = MIN_SAVE_PASSWORD_LEN;
})();
