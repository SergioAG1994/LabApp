import { constants } from "node:fs";
import { open, realpath } from "node:fs/promises";
import path from "node:path";
import { fileTypeFromBuffer } from "file-type";
import { ToolError } from "../errors.js";
const MAX_FILE = 10 * 1024 * 1024;
const binaryTypes: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".pdf": "application/pdf",
};
const textTypes: Record<string, string> = {
  ".txt": "text/plain",
  ".md": "text/markdown",
  ".csv": "text/csv",
  ".json": "application/json",
};
export async function readAttachment(root: string, supplied: string) {
  try {
    const base = await realpath(root);
    const target = path.resolve(base, supplied);
    const canonical = await realpath(target);
    const rel = path.relative(base, canonical);
    if (
      !rel ||
      rel.startsWith(".." + path.sep) ||
      rel === ".." ||
      path.isAbsolute(rel)
    )
      throw new Error();
    // Reject every symlink component, even links that currently point inside root.
    if (canonical !== target) throw new Error();
    const file = await open(
      target,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    try {
      const before = await file.stat();
      if (!before.isFile() || before.size > MAX_FILE || before.size === 0)
        throw new Error();
      // Verify the opened descriptor is still contained after open (Linux Docker).
      if (
        process.platform === "linux" &&
        (await realpath(`/proc/self/fd/${file.fd}`)) !== canonical
      )
        throw new Error();
      const buffer = Buffer.alloc(Math.min(before.size + 1, MAX_FILE + 1));
      let length = 0;
      while (length < buffer.length) {
        const read = await file.read(
          buffer,
          length,
          buffer.length - length,
          null,
        );
        if (!read.bytesRead) break;
        length += read.bytesRead;
      }
      const after = await file.stat();
      if (
        length !== before.size ||
        after.size !== before.size ||
        after.mtimeMs !== before.mtimeMs
      )
        throw new Error();
      const bytes = buffer.subarray(0, length),
        ext = path.extname(canonical).toLowerCase();
      let contentType = binaryTypes[ext];
      if (contentType) {
        if ((await fileTypeFromBuffer(bytes))?.mime !== contentType)
          throw new Error();
      } else {
        contentType = textTypes[ext];
        if (!contentType) throw new Error();
        const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
        if (/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(text)) throw new Error();
        if (ext === ".json") JSON.parse(text);
      }
      return { bytes, contentType, name: path.basename(canonical) };
    } finally {
      await file.close();
    }
  } catch {
    throw new ToolError(
      "INVALID_ATTACHMENT",
      "File must be a stable regular file inside the allowed directory, without symlinks, at most 10 MiB, and a supported type (PNG, JPEG, PDF, UTF-8 TXT/MD/CSV/JSON).",
    );
  }
}
