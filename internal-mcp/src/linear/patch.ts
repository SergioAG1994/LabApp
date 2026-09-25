import { createHash } from "node:crypto";
import { ToolError } from "../errors.js";
export interface Patch {
  anchor: string;
  replacement: string;
}
export const bodyHash = (body: string) =>
  createHash("sha256").update(body).digest("hex");
export function patchBody(
  body: string,
  patches: Patch[],
  expectedHash: string,
) {
  if (bodyHash(body) !== expectedHash)
    throw new ToolError(
      "BODY_CONFLICT",
      "The complete body changed; read again before patching.",
    );
  const ranges = patches
    .map((p) => {
      const start = body.indexOf(p.anchor);
      if (!p.anchor || start < 0 || body.indexOf(p.anchor, start + 1) !== -1)
        throw new ToolError(
          "INVALID_PATCH",
          "Each anchor must occur exactly once in the original complete body.",
        );
      return {
        start,
        end: start + p.anchor.length,
        replacement: p.replacement,
      };
    })
    .sort((a, b) => a.start - b.start);
  if (ranges.some((r, i) => i > 0 && r.start < ranges[i - 1]!.end))
    throw new ToolError("INVALID_PATCH", "Patch anchors overlap.");
  let result = body;
  for (const r of ranges.reverse())
    result = result.slice(0, r.start) + r.replacement + result.slice(r.end);
  if (result.length > 1_000_000)
    throw new ToolError(
      "BODY_TOO_LARGE",
      "Patched body exceeds the write limit.",
    );
  return result;
}
