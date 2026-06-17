/**
 * pi-pipe extension — Real-time selection tracking from Neovim via TCP.
 *
 * Neovim runs a TCP server and broadcasts cursor/selection updates as
 * newline-delimited JSON. This extension connects to that server on
 * session_start and maintains the latest selection in memory.
 *
 * On every before_agent_start, when text is selected, it's injected as
 * a context message so pi can reference it. The footer status line
 * always shows the current file and selection state.
 */

import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

interface PortFile {
  pid: number;
  port: number;
  cwd: string;
}

interface SelectionPayload {
  type: "selection";
  pid: number;
  cwd: string;
  fileUrl: string;
  relativePath: string | null;
  fileName: string;
  selection: {
    startLine: number;
    startChar: number;
    endLine: number;
    endChar: number;
    text: string;
  };
  mode: string;
}

const PORT_FILE_DIR = "/tmp/pi-pipe";

// Latest selection from Neovim (updated in real-time via TCP)
let latestSelection: SelectionPayload | null = null;

/**
 * Check if `child` is at or under `parent` in the filesystem tree.
 * Works for arbitrary depth: /a/b/c is under /a, /a/b, and /a/b/c.
 */
function isUnderOrSame(child: string, parent: string): boolean {
  if (child === parent) return true;
  // Normalize trailing slashes away; ensure we match path boundaries
  const p = parent.endsWith("/") ? parent.slice(0, -1) : parent;
  const c = child.endsWith("/") ? child.slice(0, -1) : child;
  return c.startsWith(p + "/");
}

function findPortFile(cwd: string): PortFile | null {
  let files: string[];
  try {
    files = fs.readdirSync(PORT_FILE_DIR);
  } catch {
    return null;
  }

  const candidates: PortFile[] = [];
  for (const name of files) {
    if (!name.startsWith("port-") || !name.endsWith(".json")) continue;
    try {
      const raw = fs
        .readFileSync(path.join(PORT_FILE_DIR, name), "utf-8")
        .trim();
      if (!raw) continue;
      const entry = JSON.parse(raw) as PortFile;
      if (isProcessAlive(entry.pid)) {
        candidates.push(entry);
      }
    } catch {
      // stale or malformed file, ignore
    }
  }

  // Prefer exact match, then any ancestor/descendant relationship
  for (const entry of candidates) {
    if (entry.cwd === cwd) return entry;
  }
  for (const entry of candidates) {
    if (isUnderOrSame(entry.cwd, cwd) || isUnderOrSame(cwd, entry.cwd)) {
      return entry;
    }
  }

  return null;
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function formatSelectionContext(sel: SelectionPayload): string | null {
  const file = sel.relativePath || sel.fileName;
  const { startLine, startChar, endLine, endChar } = sel.selection;
  const hasSelection =
    endLine > startLine || (endLine === startLine && endChar > startChar);

  // Only inject when user has actively selected text
  if (!hasSelection) return null;

  const parts: string[] = [];
  parts.push(`The user has selected text in ${file}:`);
  parts.push("");
  parts.push("```" + (sel.fileName.match(/\.(\w+)$/)?.[1] || ""));
  parts.push(sel.selection.text);
  parts.push("```");

  return parts.join("\n");
}

function formatStatusLine(sel: SelectionPayload): string {
  const file = sel.relativePath || sel.fileName;
  const { startLine, endLine, startChar, endChar } = sel.selection;
  const hasSelection =
    endLine > startLine || (endLine === startLine && endChar > startChar);

  if (hasSelection) {
    if (startLine === endLine) {
      return `sel: ${file}:${startLine} (${startChar}-${endChar})`;
    }
    return `sel: ${file}:${startLine}-${endLine}`;
  }
  return `${file}:${startLine}`;
}

export default function (pi: ExtensionAPI) {
  const cwd = process.cwd();
  let client: net.Socket | null = null;
  let buffer = "";
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let sessionCtx: any = null;

  function updateStatus(ctx?: any) {
    const ui = (ctx || sessionCtx);
    if (!ui?.hasUI) return;
    if (latestSelection) {
      ui.ui.setStatus("pi-pipe", formatStatusLine(latestSelection));
    } else {
      ui.ui.setStatus("pi-pipe", undefined);
    }
  }

  function connect() {
    const portFile = findPortFile(cwd);
    if (!portFile) {
      reconnectTimer = setTimeout(connect, 2000);
      return;
    }

    const socket = new net.Socket();

    socket.connect(portFile.port, "127.0.0.1", () => {
      client = socket;
      buffer = "";
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
    });

    socket.on("data", (data: Buffer) => {
      buffer += data.toString("utf-8");

      while (true) {
        const nl = buffer.indexOf("\n");
        if (nl === -1) break;
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);

        if (line) {
          try {
            latestSelection = JSON.parse(line);
            updateStatus();
          } catch {
            // Ignore malformed lines
          }
        }
      }
    });

    socket.on("close", () => {
      client = null;
      latestSelection = null;
      updateStatus();
      reconnectTimer = setTimeout(connect, 2000);
    });

    socket.on("error", () => {
      socket.destroy();
    });
  }

  pi.on("session_start", async (_event, ctx) => {
    sessionCtx = ctx;
    connect();
    updateStatus(ctx);
  });

  // Tool: let the LLM query the current nvim context on demand
  pi.registerTool({
    name: "nvim_context",
    label: "Nvim Context",
    description:
      "Get the file, cursor position, and/or selected text from the user's Neovim. " +
      "Call this when you need to know what file the user is editing, where their cursor is, " +
      "or what text they have selected. Returns null if no connection to Neovim.",
    parameters: Type.Object({}),
    async execute() {
      if (!latestSelection) {
        return {
          content: [{
            type: "text",
            text: "No Neovim connection. The user may not have Neovim running in this project.",
          }],
          details: {},
        };
      }

      const sel = latestSelection;
      const file = sel.relativePath || sel.fileName;
      const hasSelection =
        sel.selection.endLine > sel.selection.startLine ||
        (sel.selection.endLine === sel.selection.startLine &&
          sel.selection.endChar > sel.selection.startChar);

      if (hasSelection) {
        return {
          content: [{
            type: "text",
            text:
              `File: ${file}\n` +
              `Selection: L${sel.selection.startLine}:${sel.selection.startChar} - L${sel.selection.endLine}:${sel.selection.endChar}\n` +
              `\n\`\`\`${sel.fileName.match(/\.(\w+)$/)?.[1] || ""}\n${sel.selection.text}\n\`\`\``,
          }],
          details: {},
        };
      }

      return {
        content: [{
          type: "text",
          text:
            `File: ${file}\n` +
            `Cursor: line ${sel.selection.startLine}, col ${sel.selection.startChar}`,
        }],
        details: {},
      };
    },
  });

  // Inject selection as a context message + update footer status
  pi.on("before_agent_start", async (_event, ctx) => {
    updateStatus(ctx);
    if (!latestSelection) return;

    const context = formatSelectionContext(latestSelection);
    if (!context) return;
    return {
      message: {
        customType: "pi-pipe",
        content: context,
        display: false,
      },
    };
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (client) {
      client.destroy();
      client = null;
    }
    latestSelection = null;
    sessionCtx = null;
    if (ctx.hasUI) {
      ctx.ui.setStatus("pi-pipe", undefined);
    }
  });
}
