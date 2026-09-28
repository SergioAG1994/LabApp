import { createClient } from "@supabase/supabase-js";

export const runtime = "nodejs";

const roles = ["administrador", "recepcion", "analista"] as const;
type AppRole = (typeof roles)[number];

function serverConfiguration() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!url || !publishableKey || !secretKey) {
    throw new Error("Falta configurar SUPABASE_SECRET_KEY en el servidor.");
  }

  return { url, publishableKey, secretKey };
}

function bearerToken(request: Request) {
  const authorization = request.headers.get("authorization");
  return authorization?.startsWith("Bearer ") ? authorization.slice(7) : null;
}

async function authorizeAdministrator(request: Request) {
  const token = bearerToken(request);
  if (!token) return { error: Response.json({ error: "Sesión requerida." }, { status: 401 }) };

  const { url, publishableKey, secretKey } = serverConfiguration();
  const authClient = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  const { data: userData, error: userError } = await authClient.auth.getUser(token);
  if (userError || !userData.user) {
    return { error: Response.json({ error: "La sesión no es válida." }, { status: 401 }) };
  }

  const adminClient = createClient(url, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  const { data: profile, error: profileError } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", userData.user.id)
    .single();

  if (profileError || profile?.role !== "administrador") {
    return { error: Response.json({ error: "Sólo un administrador puede gestionar cuentas." }, { status: 403 }) };
  }

  return { adminClient, administrator: userData.user };
}

export async function GET(request: Request) {
  try {
    const authorization = await authorizeAdministrator(request);
    if (authorization.error) return authorization.error;

    const { adminClient } = authorization;
    const [{ data: authData, error: authError }, { data: profiles, error: profilesError }] = await Promise.all([
      adminClient.auth.admin.listUsers({ page: 1, perPage: 200 }),
      adminClient.from("profiles").select("id, full_name, role, created_at"),
    ]);

    if (authError || profilesError) {
      return Response.json({ error: authError?.message || profilesError?.message || "No se pudieron cargar las cuentas." }, { status: 500 });
    }

    const profileById = new Map((profiles || []).map((profile) => [profile.id, profile]));
    const users = authData.users.map((user) => {
      const profile = profileById.get(user.id);
      return {
        id: user.id,
        email: user.email || "",
        fullName: profile?.full_name || user.user_metadata?.full_name || "",
        role: (profile?.role === "revisor" ? "recepcion" : profile?.role || "recepcion") as AppRole,
        createdAt: profile?.created_at || user.created_at,
        confirmedAt: user.email_confirmed_at || null,
        lastSignInAt: user.last_sign_in_at || null,
      };
    });

    return Response.json({ users });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Error inesperado." }, { status: 500 });
  }
}

export async function POST(request: Request) {
  try {
    const authorization = await authorizeAdministrator(request);
    if (authorization.error) return authorization.error;

    const { adminClient, administrator } = authorization;
    const body = await request.json() as { email?: string; fullName?: string; role?: string };
    const email = body.email?.trim().toLowerCase();
    const fullName = body.fullName?.trim();
    const role = body.role as AppRole;

    if (!email || !fullName || !roles.includes(role)) {
      return Response.json({ error: "Completa nombre, correo y un rol válido." }, { status: 400 });
    }

    const configuredSiteUrl = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "");
    const redirectTo = `${configuredSiteUrl || new URL(request.url).origin}/invite`;
    const { data, error } = await adminClient.auth.admin.inviteUserByEmail(email, {
      data: { full_name: fullName },
      redirectTo,
    });

    if (error || !data.user) {
      return Response.json({ error: error?.message || "No se pudo crear la invitación." }, { status: 400 });
    }

    const { error: profileError } = await adminClient
      .from("profiles")
      .update({ full_name: fullName, role })
      .eq("id", data.user.id);

    if (profileError) {
      await adminClient.auth.admin.deleteUser(data.user.id);
      return Response.json({ error: `No se pudo asignar el rol: ${profileError.message}` }, { status: 500 });
    }

    await adminClient.from("audit_events").insert({
      actor_id: administrator.id,
      entity_type: "profiles",
      entity_id: data.user.id,
      action: "invite_user",
      after_data: { email, full_name: fullName, role },
    });

    return Response.json({ message: `Invitación enviada a ${email}.` }, { status: 201 });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Error inesperado." }, { status: 500 });
  }
}

export async function PATCH(request: Request) {
  try {
    const authorization = await authorizeAdministrator(request);
    if (authorization.error) return authorization.error;

    const { adminClient, administrator } = authorization;
    const body = await request.json() as { userId?: string; role?: string };
    const role = body.role as AppRole;

    if (!body.userId || !roles.includes(role)) {
      return Response.json({ error: "Usuario o rol inválido." }, { status: 400 });
    }
    if (body.userId === administrator.id && role !== "administrador") {
      return Response.json({ error: "No puedes retirar el permiso de administrador de tu propia cuenta." }, { status: 400 });
    }

    const { data: previous, error: previousError } = await adminClient
      .from("profiles")
      .select("role")
      .eq("id", body.userId)
      .single();
    if (previousError) return Response.json({ error: previousError.message }, { status: 400 });

    const { error } = await adminClient.from("profiles").update({ role }).eq("id", body.userId);
    if (error) return Response.json({ error: error.message }, { status: 400 });

    await adminClient.from("audit_events").insert({
      actor_id: administrator.id,
      entity_type: "profiles",
      entity_id: body.userId,
      action: "update_role",
      before_data: { role: previous.role },
      after_data: { role },
    });

    return Response.json({ message: "Permisos actualizados." });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Error inesperado." }, { status: 500 });
  }
}
