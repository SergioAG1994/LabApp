"use client";

import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabase";

type AppRole = "administrador" | "recepcion" | "analista";
type ManagedUser = {
  id: string;
  email: string;
  fullName: string;
  role: AppRole;
  createdAt: string;
  confirmedAt: string | null;
  lastSignInAt: string | null;
};

const roleOptions: Array<{ value: AppRole; label: string; description: string }> = [
  { value: "administrador", label: "Administrador", description: "Acceso completo: usuarios, personal, operación, parámetros e informes." },
  { value: "recepcion", label: "Recepción", description: "Acceso a clientes, OP, muestras, parámetros e informes; sin los paneles de personal y Reportes." },
  { value: "analista", label: "Analista", description: "Acceso únicamente a Muestras para consultar hojas de trabajo y capturar resultados." },
];

async function adminRequest(path: string, init?: RequestInit) {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) throw new Error("Tu sesión terminó. Inicia sesión nuevamente.");
  const response = await fetch(path, {
    ...init,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.access_token}`, ...init?.headers },
  });
  const payload = await response.json() as { error?: string; message?: string; users?: ManagedUser[] };
  if (!response.ok) throw new Error(payload.error || "No se pudo completar la operación.");
  return payload;
}

function formatAccountDate(value: string | null) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("es-MX", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(value));
}

export function UserManagement({ mode, currentUserId, onCancel }: { mode: "list" | "create"; currentUserId: string; onCancel: () => void }) {
  const [users, setUsers] = useState<ManagedUser[]>([]);
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<AppRole>("recepcion");
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [changingId, setChangingId] = useState<string | null>(null);
  const [message, setMessage] = useState("");

  async function loadUsers() {
    setLoading(true);
    try {
      const payload = await adminRequest("/api/admin/users");
      setUsers(payload.users || []);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudieron cargar las cuentas.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadUsers(); }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  const visibleUsers = useMemo(() => {
    const search = query.trim().toLocaleLowerCase("es-MX");
    if (!search) return users;
    return users.filter((user) => `${user.fullName} ${user.email} ${user.role}`.toLocaleLowerCase("es-MX").includes(search));
  }, [query, users]);

  async function inviteUser(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setMessage("");
    try {
      const payload = await adminRequest("/api/admin/users", {
        method: "POST",
        body: JSON.stringify({ fullName, email, role }),
      });
      setFullName(""); setEmail(""); setRole("recepcion");
      setMessage(payload.message || "Invitación enviada.");
      await loadUsers();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo enviar la invitación.");
    } finally {
      setSaving(false);
    }
  }

  async function changeRole(user: ManagedUser, nextRole: AppRole) {
    if (user.role === nextRole) return;
    setChangingId(user.id);
    setMessage("");
    try {
      const payload = await adminRequest("/api/admin/users", {
        method: "PATCH",
        body: JSON.stringify({ userId: user.id, role: nextRole }),
      });
      setUsers((current) => current.map((item) => item.id === user.id ? { ...item, role: nextRole } : item));
      setMessage(payload.message || "Permisos actualizados.");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo cambiar el rol.");
    } finally {
      setChangingId(null);
    }
  }

  return <div className="user-management">
    {mode === "create" && <form className="form-card user-invite-form" onSubmit={inviteUser}>
      <h2>Invitar usuario</h2>
      <p>La persona recibirá un correo para crear su contraseña. Su rol quedará activo desde ese momento.</p>
      <div className="form-grid">
        <label>Nombre completo<input required value={fullName} onChange={(event) => setFullName(event.target.value)} /></label>
        <label>Correo electrónico<input required type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
        <label>Permisos<select value={role} onChange={(event) => setRole(event.target.value as AppRole)}>{roleOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
      </div>
      <p className="role-help">{roleOptions.find((option) => option.value === role)?.description}</p>
      <div className="form-actions"><button type="button" className="button secondary" disabled={saving} onClick={onCancel}>Cancelar</button><button className="button primary" disabled={saving}>{saving ? "Enviando…" : "Enviar invitación"}</button></div>
    </form>}
    {message && <p className="auth-message" role="status">{message}</p>}
    {mode === "list" && <section className="table-card">
      <div className="table-toolbar"><div><h2>Cuentas con acceso</h2><p>{users.length} usuarios registrados</p></div><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Buscar usuario" aria-label="Buscar usuario" /></div>
      <div className="table-wrap"><table className="users-table"><thead><tr><th>Usuario</th><th>Correo</th><th>Permisos</th><th>Estado</th><th>Último acceso</th></tr></thead><tbody>
        {loading ? <tr><td colSpan={5}>Cargando cuentas…</td></tr> : visibleUsers.length === 0 ? <tr><td colSpan={5}>No se encontraron cuentas.</td></tr> : visibleUsers.map((user) => <tr key={user.id}><td><strong>{user.fullName || "Sin nombre"}</strong>{user.id === currentUserId && <span>Tu cuenta</span>}</td><td>{user.email}</td><td><select aria-label={`Permisos de ${user.fullName || user.email}`} value={user.role} disabled={changingId === user.id || user.id === currentUserId} onChange={(event) => void changeRole(user, event.target.value as AppRole)}>{roleOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></td><td><span className={user.confirmedAt ? "status status-green" : "status status-amber"}>{user.confirmedAt ? "Activa" : "Invitación pendiente"}</span></td><td>{formatAccountDate(user.lastSignInAt)}</td></tr>)}
      </tbody></table></div>
    </section>}
  </div>;
}
