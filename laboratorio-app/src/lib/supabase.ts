import { createClient } from "@supabase/supabase-js";
import { createPreviewFetch } from "./user-preview";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!;

let previewId: string | null = null;

export function getUserPreviewId() { return previewId; }

export function setUserPreviewId(value: string | null) {
  if (typeof window !== "undefined") previewId = value;
}

export const supabase = createClient(url, publishableKey, {
  global: { fetch: createPreviewFetch(() => previewId, (...args) => fetch(...args)) },
});
