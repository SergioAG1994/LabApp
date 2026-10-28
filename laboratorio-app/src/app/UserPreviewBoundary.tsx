"use client";

import { useCallback, useEffect, useRef, useState, type ComponentType } from "react";
import { setUserPreviewId, supabase } from "@/lib/supabase";
import { previewRoleLabels, type UserPreview } from "@/lib/user-preview";

type PreviewControls = {
  preview: UserPreview | null;
  initialView: "entries" | "users" | "samples";
  onStartPreview: (userId: string) => Promise<void>;
  onSignOut: (scope?: "global" | "local") => Promise<void>;
};

export function UserPreviewBoundary({ component: Content }: { component: ComponentType<PreviewControls> }) {
  const [preview, setPreview] = useState<UserPreview | null>(null);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState("");
  const [returnToUsers, setReturnToUsers] = useState(false);
  const [identity, setIdentity] = useState("signed-out");
  const revision = useRef(0);
  const mutating = useRef(false);
  const currentPreview = useRef<UserPreview | null>(null);
  const channel = useRef<BroadcastChannel | null>(null);

  const applyPreview = useCallback((next: UserPreview | null) => {
    currentPreview.current = next;
    setUserPreviewId(next?.id || null);
    setPreview(next);
  }, []);

  const refresh = useCallback(async () => {
    if (mutating.current) return;
    const version = ++revision.current;
    try {
      const { data: { session } } = await supabase.auth.getSession();
      let next: UserPreview | null = null;
      if (session) {
        const { data, error } = await supabase.rpc("get_user_preview");
        // Older deployments remain usable until their migration is installed.
        if (error && error.code !== "PGRST202") throw new Error(error.message);
        next = data as UserPreview | null;
      }
      if (version !== revision.current) return;
      setIdentity(session?.user.id || "signed-out");
      applyPreview(next);
      setError("");
      setReady(true);
    } catch (cause) {
      if (version !== revision.current) return;
      setError(cause instanceof Error ? cause.message : "No se pudo comprobar la vista activa.");
      setReady(false);
    }
  }, [applyPreview]);

  useEffect(() => {
    const timer = window.setTimeout(() => { void refresh(); }, 0);
    // Defer calls outside the Auth callback to avoid taking its session lock.
    const { data: { subscription } } = supabase.auth.onAuthStateChange(() => {
      window.setTimeout(() => { void refresh(); }, 0);
    });
    const sync = () => { setReady(false); void refresh(); };
    const onVisibility = () => { if (document.visibilityState === "visible") sync(); };
    const broadcast = new BroadcastChannel("labapp-user-preview");
    channel.current = broadcast;
    broadcast.onmessage = sync;
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      revision.current += 1;
      window.clearTimeout(timer);
      subscription.unsubscribe();
      broadcast.close();
      channel.current = null;
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [refresh]);

  useEffect(() => {
    if (!preview) return;
    const timer = window.setTimeout(() => { setReady(false); void refresh(); }, Math.max(0, Date.parse(preview.expiresAt) - Date.now()));
    return () => window.clearTimeout(timer);
  }, [preview, refresh]);

  async function startPreview(userId: string) {
    if (mutating.current) return;
    mutating.current = true;
    revision.current += 1;
    setReady(false);
    setError("");
    const { data, error } = await supabase.rpc("start_user_preview", { p_target_id: userId });
    mutating.current = false;
    if (error) {
      await refresh();
      setError(error.code === "PGRST202" ? "Aplica primero la migración de SER-35 en Supabase para habilitar esta función." : error.message);
      return;
    }
    applyPreview(data as UserPreview);
    setReturnToUsers(false);
    setReady(true);
    channel.current?.postMessage("changed");
  }

  async function exitPreview() {
    if (mutating.current) return false;
    mutating.current = true;
    revision.current += 1;
    setReady(false);
    const { error } = await supabase.rpc("end_user_preview");
    mutating.current = false;
    if (error) {
      setError(error.message);
      return false;
    }
    applyPreview(null);
    setError("");
    setReturnToUsers(true);
    setReady(true);
    channel.current?.postMessage("changed");
    return true;
  }

  async function signOut(scope: "global" | "local" = "global") {
    if (currentPreview.current && !(await exitPreview()) && scope === "global") return;
    const { error } = await supabase.auth.signOut({ scope });
    if (error) setError(error.message);
  }

  return <>
    {preview && <div className="user-preview-banner" role="region" aria-label="Vista simulada activa">
      <div><strong>Estás viendo el sistema como {preview.fullName} ({previewRoleLabels[preview.role]})</strong><span>Solo lectura · Tu sesión sigue siendo la de administrador.</span></div>
      <button type="button" className="button secondary" aria-label="Salir de vista simulada" onClick={() => void exitPreview()}>Salir de vista simulada</button>
    </div>}
    {error && <div className="user-preview-error" role="alert">{error}<button type="button" className="button secondary" onClick={() => void refresh()}>Reintentar</button></div>}
    {ready ? <div key={preview ? `${preview.id}:${preview.role}` : `normal:${identity}`} className={preview ? "user-preview-content" : undefined}>
      <Content preview={preview} initialView={preview?.role === "analista" ? "samples" : preview ? "entries" : returnToUsers ? "users" : "entries"} onStartPreview={startPreview} onSignOut={signOut} />
    </div> : <main className="auth-page"><p>{error ? "No se puede abrir el sistema hasta comprobar la sesión." : "Comprobando la vista autorizada…"}</p></main>}
  </>;
}
