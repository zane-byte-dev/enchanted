#!/usr/bin/env node

import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const executable = process.env.PI_EXECUTABLE || `${process.env.HOME}/.local/bin/pi`;
const cwd = process.cwd();
const temporaryDirectory = await mkdtemp(join(tmpdir(), "enchanted-pi-rpc-"));
const sessionPath = join(temporaryDirectory, "history-sync.jsonl");
const extensionPath = join(temporaryDirectory, "permission-gate.ts");
const backendConfig = await readFile(join(cwd, "Enchanted/Agent/AgentBackendConfig.swift"), "utf8");
const extensionSource = backendConfig.match(/let source = #"""([\s\S]*?)"""#/)?.[1];
if (!extensionSource) throw new Error("Could not extract the generated permission gate extension");
if (!extensionSource.includes('name: "update_plan"')) {
  throw new Error("Generated extension is missing the structured plan tool");
}
await writeFile(extensionPath, extensionSource);
const now = new Date().toISOString();
const records = [
  { type: "session", version: 3, id: "enchanted-rpc-test", timestamp: now, cwd },
  { type: "message", id: "u1", parentId: null, timestamp: now, message: { role: "user", content: [{ type: "text", text: "local turn one" }], timestamp: Date.now() } },
  { type: "message", id: "a1", parentId: "u1", timestamp: now, message: { role: "assistant", content: [{ type: "text", text: "assistant one" }], timestamp: Date.now() } },
  { type: "message", id: "u2", parentId: "a1", timestamp: now, message: { role: "user", content: [{ type: "text", text: "local turn two" }], timestamp: Date.now() } },
  { type: "message", id: "a2", parentId: "u2", timestamp: now, message: { role: "assistant", content: [{ type: "text", text: "assistant two" }], timestamp: Date.now() } },
];
await writeFile(sessionPath, `${records.map((record) => JSON.stringify(record)).join("\n")}\n`);

const child = spawn(executable, ["--mode", "rpc", "--extension", extensionPath], { cwd, stdio: ["pipe", "pipe", "inherit"] });
const lines = createInterface({ input: child.stdout });
const pending = new Map();
lines.on("line", (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.type === "response" && message.id && pending.has(message.id)) {
    pending.get(message.id)(message);
    pending.delete(message.id);
  }
});

let commandID = 0;
function request(command, timeout = 10_000) {
  const id = `test-${++commandID}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for ${command.type}`));
    }, timeout);
    pending.set(id, (response) => {
      clearTimeout(timer);
      if (!response.success) reject(new Error(response.error || `${command.type} failed`));
      else resolve(response);
    });
    child.stdin.write(`${JSON.stringify({ id, ...command })}\n`);
  });
}

try {
  await request({ type: "set_auto_compaction", enabled: true });
  await request({ type: "switch_session", sessionPath });
  const response = await request({ type: "get_fork_messages" });
  const turns = response.data?.messages?.map((message) => message.text) || [];
  const expected = ["local turn one", "local turn two"];
  if (JSON.stringify(turns) !== JSON.stringify(expected)) {
    throw new Error(`Unexpected reconstructed turns: ${JSON.stringify(turns)}`);
  }
  console.log("pi RPC verification passed: permission/plan extension load + auto compact + v3 history rebuild");
} finally {
  child.kill("SIGTERM");
  lines.close();
  await rm(temporaryDirectory, { recursive: true, force: true });
}
