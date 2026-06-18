/**
 * Pure helpers for pi-pipe — no external deps, safe to unit test.
 */

/**
 * Check if `child` is at or under `parent` in the filesystem tree.
 * Works for arbitrary depth: /a/b/c is under /a, /a/b, and /a/b/c.
 */
export function isUnderOrSame(child: string, parent: string): boolean {
  if (child === parent) return true;
  // Normalize trailing slashes away; ensure we match path boundaries
  const p = parent.endsWith("/") ? parent.slice(0, -1) : parent;
  const c = child.endsWith("/") ? child.slice(0, -1) : child;
  return c.startsWith(p + "/");
}

/**
 * Parse pid from a socket filename like "pipe-12345.sock".
 * Returns null if the format is wrong or the process is no longer alive.
 */
export function parsePidFromSocket(name: string): number | null {
  const match = name.match(/^pipe-(\d+)\.sock$/);
  if (!match) return null;
  const pid = parseInt(match[1], 10);
  try {
    process.kill(pid, 0);
    return pid;
  } catch {
    return null; // process not alive
  }
}
