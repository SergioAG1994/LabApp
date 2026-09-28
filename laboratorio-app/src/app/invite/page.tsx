"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

export default function AcceptInvitation() {
  const [ready, setReady] = useState(false);
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("Validando invitación…");

  useEffect(() => {
    let mounted = true;
    const prepareSession = async () => {
      const code = new URLSearchParams(window.location.search).get("code");
      if (code) await supabase.auth.exchangeCodeForSession(code);
      const { data: { session } } = await supabase.auth.getSession();
      if (!mounted) return;
      setReady(Boolean(session));
      setMessage(session ? "" : "La invitación no es válida o ya venció. Solicita una nueva al administrador.");
    };
    void prepareSession();
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!mounted || !session) return;
      setReady(true);
      setMessage("");
    });
    return () => { mounted = false; subscription.unsubscribe(); };
  }, []);

  async function setAccountPassword(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    if (password !== confirmation) {
      setMessage("Las contraseñas no coinciden.");
      return;
    }
    setSaving(true);
    const { error } = await supabase.auth.updateUser({ password });
    setSaving(false);
    if (error) {
      setMessage(error.message);
      return;
    }
    await supabase.auth.signOut();
    window.location.assign("/");
  }

  return <main className="auth-page"><section className="auth-card">
    <div className="auth-brand"><span>LA</span><div><strong>LabAqua</strong><small>Control de análisis</small></div></div>
    <p className="eyebrow">ACTIVAR CUENTA</p><h1>Crea tu contraseña</h1>
    <p className="auth-description">Define una contraseña personal para terminar de activar tu acceso.</p>
    {ready && <form className="auth-form" onSubmit={setAccountPassword}><label>Nueva contraseña<input required type="password" minLength={8} value={password} onChange={(event) => setPassword(event.target.value)} /></label><label>Confirmar contraseña<input required type="password" minLength={8} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} /></label><button className="button primary full" disabled={saving}>{saving ? "Guardando…" : "Activar cuenta"}</button></form>}
    {message && <p className="auth-message" role="status">{message}</p>}
  </section></main>;
}
