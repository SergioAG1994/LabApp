export type UserPreview = {
  id: string;
  userId: string;
  fullName: string;
  role: "administrador" | "recepcion" | "analista";
  expiresAt: string;
};

export const previewRoleLabels = { administrador: "Administrador", recepcion: "Recepción", analista: "Analista" };

const controlPaths = new Set(["/rpc/get_user_preview", "/rpc/start_user_preview", "/rpc/end_user_preview"]);
const readPaths = new Set([
  "/rpc/list_staff_samples", "/rpc/list_completed_staff_samples", "/rpc/load_staff_sample_worksheet",
  "/rpc/list_assignable_staff", "/rpc/list_sample_report_staff",
]);

// This is UI defense in depth. The database pre-request hook independently
// enforces the same restrictions, even if a caller removes the preview header.
export function createPreviewFetch(getPreviewId: () => string | null, upstream: typeof fetch): typeof fetch {
  return async (input, init) => {
    const previewId = getPreviewId();
    const url = new URL(input instanceof Request ? input.url : String(input));
    const path = url.pathname.startsWith("/rest/v1/") ? url.pathname.slice("/rest/v1".length) : null;
    if (!previewId || !path || controlPaths.has(path)) return upstream(input, init);
    const method = (init?.method || (input instanceof Request ? input.method : "GET")).toUpperCase();
    const allowed = path.startsWith("/rpc/")
      ? readPaths.has(path) && ["GET", "HEAD", "POST"].includes(method)
      : ["GET", "HEAD"].includes(method);
    if (!allowed) return Response.json({ code: "42501", message: "La vista simulada es de solo lectura." }, { status: 403 });
    const headers = new Headers(init?.headers || (input instanceof Request ? input.headers : undefined));
    headers.set("x-user-preview", previewId);
    const response = await upstream(input, { ...init, headers, cache: "no-store" });
    if (getPreviewId() !== previewId) throw new Error("La vista cambió durante la consulta. Vuelve a abrir la pantalla.");
    return response;
  };
}
