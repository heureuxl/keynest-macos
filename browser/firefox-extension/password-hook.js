/**
 * 拦截 HTMLInputElement.value 赋值：站点把密码框设成单字符掩码时，不污染真实明文缓冲。
 */
(function () {
  "use strict";

  const truePlainByEl = new WeakMap();
  const pickBetter = globalThis.__keynestPickBetterPlain || ((a, b) => (b && b.length >= (a || "").length ? b : a || ""));

  function isPasswordLike(el) {
    if (!(el instanceof HTMLInputElement)) return false;
    if (el.type === "password") return true;
    const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
    if (ac === "current-password" || ac === "new-password") return true;
    const blob =
      (el.name || "") +
      (el.id || "") +
      (el.getAttribute("aria-label") || "") +
      (el.placeholder || "");
    if (/password|passwd|pwd|密码/i.test(blob)) {
      const t = (el.type || "text").toLowerCase();
      return t === "text" || t === "tel" || t === "" || t === "search";
    }
    return false;
  }

  function recordTruePlain(el, plain) {
    if (!plain || !isPasswordLike(el)) return;
    const p = String(plain);
    if (p.length === 1) return;
    const prev = truePlainByEl.get(el) || "";
    const best = pickBetter(prev, p);
    truePlainByEl.set(el, best);
    const pub = globalThis.__keynestPublishPageCredential;
    if (typeof pub === "function") pub(best, "");
  }

  function getHookedPlain(el) {
    return truePlainByEl.get(el) || "";
  }

  try {
    const proto = HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, "value");
    if (desc && typeof desc.set === "function" && typeof desc.get === "function" && !proto.__keynestValueHooked) {
      const nativeGet = desc.get;
      const nativeSet = desc.set;
      Object.defineProperty(proto, "value", {
        configurable: true,
        enumerable: desc.enumerable,
        get() {
          return nativeGet.call(this);
        },
        set(v) {
          nativeSet.call(this, v);
          if (isPasswordLike(this)) {
            const s = String(v ?? "");
            if (s.length >= 2) recordTruePlain(this, s);
          }
        },
      });
      proto.__keynestValueHooked = true;
    }
  } catch (_) {}

  globalThis.__keynestGetHookedPlain = getHookedPlain;
  globalThis.__keynestRecordTruePlain = recordTruePlain;
  globalThis.__keynestIsPasswordLikeInput = isPasswordLike;
})();
