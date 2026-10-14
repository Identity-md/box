#!/usr/bin/env node
// The box's browser tool: Playwright MCP 0.0.82, the version IMD's website skills are written
// against, driving Chrome Headless Shell. In a task's workspace it also serves the task's `dist/` on
// loopback under /preview/ and writes that address to test/scratch/browser/preview.json, the
// contract in the better-interface reference. The worker deletes test/scratch/ before anything is
// submitted, and the preview stops when the MCP server does.
import { execFileSync, spawn } from "node:child_process";
import { createReadStream, existsSync, mkdirSync, readdirSync, realpathSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { extname, join, resolve, sep } from "node:path";

const HOME = "/opt/imd-browser";
const BROWSERS = join(HOME, "browsers");
const MCP = join(HOME, "node_modules/@playwright/mcp/cli.js");

// chromium_headless_shell-<revision>/chrome-headless-shell-linux<arch>/chrome-headless-shell
function headlessShell() {
  for (const revision of readdirSync(BROWSERS).filter((name) => name.startsWith("chromium_headless_shell-"))) {
    for (const build of readdirSync(join(BROWSERS, revision))) {
      const binary = join(BROWSERS, revision, build, "chrome-headless-shell");
      if (existsSync(binary)) return binary;
    }
  }
  throw new Error(`no Chrome Headless Shell in ${BROWSERS}`);
}

// The worker's probe. It answers only when the browser itself starts here, so a box missing a
// library never advertises a browser it cannot open.
if (process.argv[2] === "--version") {
  try {
    if (!existsSync(MCP)) throw new Error(`no Playwright MCP at ${MCP}`);
    const version = execFileSync(headlessShell(), ["--version"], { timeout: 4000, encoding: "utf8" }).trim();
    console.log(`imd-browser: Playwright MCP 0.0.82, ${version}`);
    process.exit(0);
  } catch (error) {
    console.error(`imd-browser: the browser cannot start here: ${String(error.message).split("\n")[0]}`);
    process.exit(1);
  }
}

const workspace = process.cwd();
const scratch = join(workspace, "test/scratch/browser");
const previewFile = join(scratch, "preview.json");
// A probe runs from / or the home folder; only a task's workspace gets a preview.
const inTask = workspace !== "/" && resolve(workspace) !== resolve(homedir());

const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json", ".map": "application/json", ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml", ".webmanifest": "application/manifest+json", ".wasm": "application/wasm",
  ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
  ".webp": "image/webp", ".avif": "image/avif", ".ico": "image/x-icon",
  ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf",
  ".mp4": "video/mp4", ".webm": "video/webm", ".mp3": "audio/mpeg", ".wav": "audio/wav", ".ogg": "audio/ogg",
  ".pdf": "application/pdf", ".glb": "model/gltf-binary", ".gltf": "model/gltf+json",
};

// The current dist/ on every request, so a rebuild shows on reload. No fallback to index.html for
// unknown paths: a broken route or asset should look broken here, as it will once published.
function serve(request, response) {
  const send = (status, headers = {}) => response.writeHead(status, { "cache-control": "no-store", ...headers }).end();
  if (request.method !== "GET" && request.method !== "HEAD") return send(405, { allow: "GET, HEAD" });
  const { pathname, search } = new URL(request.url, "http://127.0.0.1");
  if (pathname === "/" || pathname === "/preview") return send(302, { location: "/preview/" });
  if (!pathname.startsWith("/preview/")) return send(404);
  let path;
  try {
    path = decodeURIComponent(pathname.slice("/preview/".length));
  } catch {
    return send(400);
  }
  if (path.includes("\0")) return send(400);
  const root = join(workspace, "dist");
  let file;
  try {
    const realRoot = realpathSync(root);
    file = realpathSync(join(root, path));
    if (file !== realRoot && !file.startsWith(realRoot + sep)) return send(404);
    if (statSync(file).isDirectory()) {
      // As a static host does, so the folder's relative links resolve inside it.
      if (!pathname.endsWith("/")) return send(301, { location: `${pathname}/${search}` });
      file = realpathSync(join(file, "index.html"));
    }
    if (!file.startsWith(realRoot + sep) || !statSync(file).isFile()) return send(404);
  } catch {
    return send(404);
  }
  response.writeHead(200, {
    "content-type": TYPES[extname(file).toLowerCase()] ?? "application/octet-stream",
    "content-length": statSync(file).size,
    "cache-control": "no-store",
  });
  if (request.method === "HEAD") return response.end();
  createReadStream(file).pipe(response);
}

function startMcp() {
  // Chromium's own sandbox needs Linux features Docker turns off; the box is its sandbox.
  const args = [MCP, "--headless", "--isolated", "--browser", "chromium", "--executable-path", headlessShell(), "--no-sandbox"];
  if (inTask) args.push("--output-dir", scratch);
  const child = spawn(process.execPath, [...args, ...process.argv.slice(2)], {
    stdio: "inherit",
    env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: BROWSERS },
  });
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, () => child.kill(signal));
  child.on("exit", (code, signal) => {
    if (inTask) {
      try {
        unlinkSync(previewFile);
      } catch {}
    }
    process.exit(code ?? (signal ? 1 : 0));
  });
}

if (!inTask) {
  startMcp();
} else {
  const server = createServer(serve);
  server.listen(0, "127.0.0.1", () => {
    mkdirSync(scratch, { recursive: true });
    writeFileSync(previewFile, `${JSON.stringify({ url: `http://127.0.0.1:${server.address().port}/preview/` })}\n`);
    startMcp();
  });
}
