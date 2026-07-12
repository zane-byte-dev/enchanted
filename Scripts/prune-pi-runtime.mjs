#!/usr/bin/env node

// Offline production-dependency closure for the pi monorepo. npm prune on a
// reduced workspace can consult the registry and is therefore unsuitable for
// a deterministic release build. This walks the dependencies actually
// installed by the lockfile and removes unrelated top-level packages only.
import { readdir, readFile, realpath, rm, stat } from "node:fs/promises";
import { dirname, join, relative, sep } from "node:path";

const inputRoot = process.argv[2];
if (!inputRoot) throw new Error("usage: prune-pi-runtime.mjs <pi-source-copy>");
const root = await realpath(inputRoot);
const nodeModules = await realpath(join(root, "node_modules"));
const roots = ["ai", "agent", "tui", "coding-agent"].map((name) => join(root, "packages", name));
const visited = new Set();
const keepTopLevel = new Set();

function topLevelName(packageDirectory) {
  const value = relative(nodeModules, packageDirectory).split(sep);
  if (value[0] === ".." || value[0] === "") return null;
  return value[0].startsWith("@") ? `${value[0]}/${value[1]}` : value[0];
}

async function packageDirectoryFor(name, fromPackageJSON) {
  let cursor = dirname(fromPackageJSON);
  while (cursor !== dirname(cursor)) {
    const candidate = join(cursor, "node_modules", name);
    try {
      const value = JSON.parse(await readFile(join(candidate, "package.json"), "utf8"));
      if (value.name === name) return candidate;
    } catch {}
    cursor = dirname(cursor);
  }
  throw new Error(`Could not resolve production dependency ${name} from ${fromPackageJSON}`);
}

async function visit(packageDirectory) {
  const canonical = await realpath(packageDirectory);
  if (visited.has(canonical)) return;
  visited.add(canonical);
  const packageJSON = join(canonical, "package.json");
  const value = JSON.parse(await readFile(packageJSON, "utf8"));
  const dependencies = {
    ...(value.dependencies ?? {}),
    ...(value.optionalDependencies ?? {}),
    ...(value.peerDependencies ?? {}),
  };
  for (const name of Object.keys(dependencies)) {
    try {
      const dependencyDirectory = await packageDirectoryFor(name, packageJSON);
      const topLevel = topLevelName(dependencyDirectory);
      if (topLevel) keepTopLevel.add(topLevel);
      await visit(dependencyDirectory);
    } catch (error) {
      if (name in (value.optionalDependencies ?? {}) || value.peerDependenciesMeta?.[name]?.optional) continue;
      throw error;
    }
  }
}

for (const packageDirectory of roots) await visit(packageDirectory);

for (const entry of await readdir(nodeModules)) {
  const entryPath = join(nodeModules, entry);
  if (entry.startsWith("@") && (await stat(entryPath)).isDirectory()) {
    for (const child of await readdir(entryPath)) {
      if (!keepTopLevel.has(`${entry}/${child}`)) {
        await rm(join(entryPath, child), { recursive: true, force: true });
      }
    }
    if ((await readdir(entryPath)).length === 0) await rm(entryPath, { recursive: true, force: true });
  } else if (!keepTopLevel.has(entry)) {
    await rm(entryPath, { recursive: true, force: true });
  }
}

process.stdout.write(`Kept ${keepTopLevel.size} production packages\n`);
