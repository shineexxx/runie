import { closeMainWindow, open, showHUD } from "@raycast/api";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

/** Sends a command to Runie through its `runie://` link. Runie launches itself if it was closed. */
export async function openRunie(
  command: "ask" | "open" | "new",
  text?: string,
) {
  const query = text ? `?q=${encodeURIComponent(text)}` : "";
  try {
    await open(`runie://${command}${query}`);
    await closeMainWindow();
  } catch {
    await showHUD("Runie is not installed — put Runie.app in Applications");
  }
}

/** Runie's index: a plain SQLite database next to the app. */
export const indexPath = join(
  homedir(),
  "Library/Application Support/Runie/Index/index.sqlite",
);

export const hasIndex = () => existsSync(indexPath);

export type Source =
  "files" | "mail" | "notes" | "messages" | "photos" | "history";

export interface Hit {
  source: Source;
  externalID: string;
  title: string;
  body: string;
  date: number;
  details: Record<string, string>;
}

/**
 * Word stem, cut the same way Runie cuts it: long Russian words lose their
 * ending so that "бюджета" still finds "бюджет". Latin words stay as they are.
 */
export function stem(word: string): string {
  if (!/[а-яё]/i.test(word)) return word;
  const folded = word.replaceAll("ё", "е");
  if (folded.length < 6) return folded;
  const keep = Math.max(5, folded.length - (folded.length >= 9 ? 3 : 2));
  return folded.slice(0, keep);
}

/** Full-text query. Only letters and digits survive — no quotes, no operators. */
export function ftsQuery(text: string): string {
  const words = text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .map(stem)
    .filter((word) => word.length >= 2);
  return words.map((word) => `"${word}"*`).join(" AND ");
}

const columns = `items.source AS source, items.external_id AS externalID, items.title AS title,
  substr(items.body, 1, 400) AS body, items.date AS date, items.details AS details`;

/**
 * Searches by words. Searching by meaning lives in Runie itself — it needs its
 * model — so the list offers "Ask Runie" for that.
 */
export async function search(text: string, limit = 40): Promise<Hit[]> {
  if (!hasIndex()) return [];
  const match = ftsQuery(text);
  const sql = match
    ? `SELECT ${columns} FROM items_fts JOIN items ON items.id = items_fts.rowid
       WHERE items_fts MATCH '${match.replaceAll("'", "''")}'
       ORDER BY bm25(items_fts, 3.0, 1.0) LIMIT ${limit};`
    : `SELECT ${columns} FROM items ORDER BY items.date DESC LIMIT ${limit};`;

  // Read-only: the index belongs to Runie, not to us.
  const { stdout } = await run(
    "/usr/bin/sqlite3",
    ["-readonly", "-json", indexPath, sql],
    {
      maxBuffer: 16 * 1024 * 1024,
    },
  );
  if (!stdout.trim()) return [];
  const rows = JSON.parse(stdout) as Array<
    Omit<Hit, "details"> & { details: string }
  >;
  return rows.map((row) => ({ ...row, details: safeJSON(row.details) }));
}

function safeJSON(text: string): Record<string, string> {
  try {
    return JSON.parse(text) as Record<string, string>;
  } catch {
    return {};
  }
}
