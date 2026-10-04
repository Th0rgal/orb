import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { expect, it } from "vitest";
import ts from "typescript";

it("permits and registers every statically invoked native command", () => {
  const native = resolve("src-tauri");
  const capability = JSON.parse(readFileSync(resolve(native, "capabilities/default.json"), "utf8"));
  const allowed = new Set<string>();
  for (const file of readdirSync(resolve(native, "permissions"))) {
    if (!file.endsWith(".toml")) continue;
    const text = readFileSync(resolve(native, "permissions", file), "utf8");
    for (const permission of text.split("[[permission]]").slice(1)) {
      const id = permission.match(/identifier\s*=\s*"([^"]+)"/)?.[1];
      if (!capability.permissions.includes(id)) continue;
      const commands = permission.match(/commands\.allow\s*=\s*\[([^\]]*)\]/)?.[1] ?? "";
      for (const command of commands.matchAll(/^\s*"([^"]+)"/gm)) allowed.add(command[1]);
    }
  }
  const main = readFileSync(resolve(native, "src/main.rs"), "utf8");
  const handler = main.split("tauri::generate_handler![")[1].split("]")[0];
  const registered = new Set(handler.split(",").map(name => name.trim().split("::").at(-1)));
  const missing: string[] = [];
  for (const file of readdirSync(resolve("src"))) {
    if (!/\.tsx?$/.test(file)) continue;
    const source = ts.createSourceFile(file, readFileSync(resolve("src", file), "utf8"), ts.ScriptTarget.Latest, true);
    const visit = (node: ts.Node) => {
      if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "invoke") {
        const argument = node.arguments[0];
        if (argument && ts.isStringLiteral(argument) && !argument.text.startsWith("plugin:")) {
          if (!registered.has(argument.text)) missing.push(`${file}: ${argument.text} is not registered`);
          if (!allowed.has(argument.text)) missing.push(`${file}: ${argument.text} is not permitted`);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  expect(missing).toEqual([]);
});
