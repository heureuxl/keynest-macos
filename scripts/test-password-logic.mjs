#!/usr/bin/env node
/**
 * 密码明文合并逻辑自检（不依赖浏览器）
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import vm from "vm";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const code = readFileSync(join(root, "browser/chrome-extension/password-plain.js"), "utf8");
const ctx = vm.createContext({ globalThis: {} });
ctx.globalThis = ctx;
vm.runInContext(code, ctx);

const {
  __keynestPickBetterPlain: pick,
  __keynestBestPlainFromSources: best,
  __keynestIsSaveablePassword: ok,
} = ctx;

let failed = 0;
function assert(name, cond) {
  if (!cond) {
    console.error("FAIL:", name);
    failed++;
  } else {
    console.log("ok:", name);
  }
}

assert("掩码不覆盖长密码", pick("secret12", "8") === "secret12");
assert("长密码覆盖掩码", pick("8", "secret12") === "secret12");
assert("仅1字符来源返回空", best(["8"]) === "");
assert("仅1字符来源返回空2", best(["8"]) === "");
assert("有长来源时取最长", best(["ab", "abc", "•"]) === "abc");
assert("密文不覆盖明文", best(["hello", "a".repeat(80)]) === "hello");
assert("pick长掩码短", pick("secret12", "8") === "secret12");
assert("pick短掩码长", pick("8", "secret12") === "secret12");
assert("可保存长度", ok("ab") && !ok("•") && !ok(""));

if (failed) {
  process.exit(1);
}
console.log("全部密码逻辑自检通过");
