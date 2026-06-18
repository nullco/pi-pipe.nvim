/**
 * pi-pipe extension — Real-time selection tracking from Neovim via Unix socket.
 *
 * Neovim runs a Unix domain socket server and broadcasts cursor/selection
 * updates as newline-delimited JSON. This extension connects to that server
 * on session_start and maintains the latest selection in memory.
 *
 * On every before_agent_start, when text is selected, it's injected as
 * a context message so pi can reference it. The footer status line
 * always shows the current file and selection state.
 */

import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { isUnderOrSame, parsePidFromSocket } from "./helpers.ts";

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

interface HandshakePayload {
  type: "handshake";
  cwd: string;
}

const SOCKET_DIR = "/tmp/pi-pipe";

// Latest selection from Neovim (updated in real-time via Unix socket)
let latestSelection: SelectionPayload | null = null;

// Active theme instance — captured once at session_start so we can style
// the footer status to match pi's built-in footer (which uses theme.fg("dim", ...)).
// The theme export is a Proxy that reads from globalThis, so this reference
// automatically tracks theme switches.
let activeTheme: Theme | null = null;

/**
 * Scan /tmp/pi-pipe/ for .sock files. Returns array of { pid, path } for
 * alive processes. The cwd is not known yet — we try connecting first.
 */
function findSocketPaths(): { pid: number; path: string }[] {
  let files: string[];
  try {
    files = fs.readdirSync(SOCKET_DIR);
  } catch {
    return [];
  }

  const result: { pid: number; path: string }[] = [];
  for (const name of files) {
    const pid = parsePidFromSocket(name);
    if (pid !== null) {
      result.push({ pid, path: path.join(SOCKET_DIR, name) });
    }
  }
  return result;
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
  let sessionCtx: ExtensionContext | null = null;

  function updateStatus(ctx?: any) {
    const ui = (ctx || sessionCtx);
    if (!ui?.hasUI) return;
    if (latestSelection) {
      const text = formatStatusLine(latestSelection);
      // Match the built-in footer's dim style so the status blends in
      // with pwd, token stats, and git branch.
      const styled = activeTheme ? activeTheme.fg("dim", text) : text;
      ui.ui.setStatus("pi-pipe", styled);
    } else {
      ui.ui.setStatus("pi-pipe", undefined);
    }
  }

  function connect() {
    const sockets = findSocketPaths();
    if (sockets.length === 0) {
      reconnectTimer = setTimeout(connect, 2000);
      return;
    }

    // Try each socket sequentially. The first one whose handshake
    // matches our cwd (or is an ancestor/descendant) wins.
    let idx = 0;
    let resolved = false;

    function tryNext() {
      if (resolved) return;
      if (idx >= sockets.length) {
        reconnectTimer = setTimeout(connect, 2000);
        return;
      }

      const entry = sockets[idx++];
      const socket = net.createConnection(entry.path);
      let handshakeBuf = "";

      // Abandon this attempt if no handshake lands within 1s; move to next.
      const abandonTimer = setTimeout(() => {
        if (!resolved) {
          socket.destroy();
        }
      }, 1000);

      socket.on("data", (data: Buffer) => {
        if (!resolved) {
          // Still waiting for handshake
          handshakeBuf += data.toString("utf-8");

          const nl = handshakeBuf.indexOf("\n");
          if (nl === -1) return;

          const line = handshakeBuf.slice(0, nl);
          const rest = handshakeBuf.slice(nl + 1);

          let handshake: HandshakePayload;
          try {
            handshake = JSON.parse(line);
          } catch {
            clearTimeout(abandonTimer);
            socket.destroy();
            return;
          }

          if (handshake.type !== "handshake") {
            clearTimeout(abandonTimer);
            socket.destroy();
            return;
          }

          // Check cwd match
          if (
            handshake.cwd !== cwd &&
            !isUnderOrSame(handshake.cwd, cwd) &&
            !isUnderOrSame(cwd, handshake.cwd)
          ) {
            clearTimeout(abandonTimer);
            socket.destroy();
            return;
          }

          // Matched! Keep this connection.
          resolved = true;
          clearTimeout(abandonTimer);
          client = socket;
          buffer = rest;
          if (reconnectTimer) {
            clearTimeout(reconnectTimer);
            reconnectTimer = null;
          }

          // Process any remaining data from the handshake chunk
          processBuffer();
        } else {
          // After handshake, accumulate and process selection messages
          buffer += data.toString("utf-8");
          processBuffer();
        }
      });

      socket.on("error", () => {
        clearTimeout(abandonTimer);
        socket.destroy();
        if (!resolved) tryNext();
      });

      socket.on("close", () => {
        clearTimeout(abandonTimer);
        if (resolved) {
          // Our active connection dropped
          client = null;
          latestSelection = null;
          updateStatus();
          reconnectTimer = setTimeout(connect, 2000);
        }
      });
    }

    tryNext();
  }

  function processBuffer() {
    while (true) {
      const nl = buffer.indexOf("\n");
      if (nl === -1) break;
      const line = buffer.slice(0, nl);
      buffer = buffer.slice(nl + 1);

      if (line) {
        try {
          const msg = JSON.parse(line);
          if (msg.type === "selection") {
            latestSelection = msg;
            updateStatus();
          }
        } catch {
          // Ignore malformed lines
        }
      }
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    sessionCtx = ctx;

    // Capture the active theme instance by briefly installing a throwaway
    // footer factory. The factory receives the live theme proxy as its
    // second argument; we stash it and immediately restore the built-in
    // footer. The proxy reads from globalThis, so it tracks theme switches.
    if (ctx.hasUI) {
      ctx.ui.setFooter((_tui, theme, _data) => {
        activeTheme = theme;
        return { render: () => [] };
      });
      ctx.ui.setFooter(undefined);
    }

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
    activeTheme = null;
    if (ctx.hasUI) {
      ctx.ui.setStatus("pi-pipe", undefined);
    }
  });
}
