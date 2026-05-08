/**
 * 与 React / Vue 等受控输入兼容：不能仅用 el.value = x，否则失焦后会被框架覆盖。
 * 由 content / popup 注入后通过 globalThis.__keynestFillCredentials 调用。
 */
(function () {
  "use strict";

  /**
   * @param {HTMLInputElement | HTMLTextAreaElement} el
   * @param {string} value
   */
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

    // React 15–18：让内部 _valueTracker 与 DOM 同步后再派发 input
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
  }

  function pickUsernameInput() {
    return (
      document.querySelector('input[type="email"]') ||
      document.querySelector('input[name="username"]') ||
      document.querySelector('input[id="username"]') ||
      document.querySelector('input[type="text"][autocomplete="username"]') ||
      document.querySelector('input[type="text"]')
    );
  }

  function pickPasswordInput() {
    return (
      document.querySelector('input[type="password"][autocomplete="current-password"]') ||
      document.querySelector('input[type="password"]')
    );
  }

  /**
   * @param {{ username?: string, password?: string }} cred
   */
  function fillCredentials(cred) {
    if (!cred) return;
    const userEl = pickUsernameInput();
    const passEl = pickPasswordInput();

    if (userEl && cred.username != null) {
      userEl.focus({ preventScroll: true });
      setNativeValue(userEl, cred.username);
    }

    const fillPass = () => {
      if (passEl && cred.password != null) {
        passEl.focus({ preventScroll: true });
        setNativeValue(passEl, cred.password);
      }
    };

    // 部分站点在用户名字段更新后会异步切换「下一步」或重绘密码框，延后一拍再填密码更稳
    if (passEl && cred.password != null) {
      setTimeout(fillPass, userEl && cred.username != null ? 16 : 0);
    }
  }

  globalThis.__keynestFillCredentials = fillCredentials;
})();
