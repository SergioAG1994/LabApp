export class ToolError extends Error {
  constructor(
    public code: string,
    message: string,
    public details: Record<string, unknown> = {},
  ) {
    super(message);
  }
}
export function publicError(error: unknown) {
  return error instanceof ToolError
    ? { code: error.code, message: error.message, ...error.details }
    : {
        code: "INTERNAL_ERROR",
        message: "Operation failed; consult the server operator.",
      };
}
