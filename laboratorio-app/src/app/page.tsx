"use client";
import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { MultiSampleOrderForm } from "./MultiSampleOrderForm";
import { ParameterDirectory } from "./ParameterDirectory";
import { PersonnelDirectory } from "./PersonnelDirectory";
import { ReportPreview } from "./ReportPreview";
type Entry = {
    id: string;
    op: string;
    client: string;
    clientBranch?: string | null;
    clientAddress?: string | null;
    clientRfc?: string | null;
    clientPhone?: string | null;
    clientContact?: string | null;
    samplingNumber: string;
    sampler: string;
    quotation: string;
    received: string;
    due: string;
    reportNumber: string;
    analysis: string;
    sampleNumber: string;
    sampleId: string;
    analysisOrderCreatedAt: string | null;
    sampledAt: string | null;
    issuedAt: string | null;
    isCancelled: boolean;
    status?: string;
};
type OrderGroup = {
    id: string;
    representative: Entry;
    samples: Entry[];
    analysis: string;
    sampleRange: string;
};
type OrderRow = {
    id: string;
    label: string;
    unit: string | null;
    row_type: "result" | "aggregate";
    uncertainty: string | null;
    result_value: string | null;
    analyst_reference: string | null;
    result_date: string | null;
    analyst_name: string | null;
    released_by: string | null;
    par_form: string | null;
    method_reference: string | null;
};
type ClientRecord = {
    id: string;
    client_number: number;
    name: string;
    branch: string | null;
    address: string | null;
    contact_name: string | null;
    email: string | null;
    rfc: string | null;
    phone: string | null;
};
type AppRole = "administrador" | "recepcion" | "analista" | "revisor";
type StaffSample = {
    order_id: string;
    sample_id: string;
    sample_code: string;
    received_at: string | null;
    due_date: string | null;
    analysis_order_created_at: string | null;
    total_results: number;
    captured_results: number;
    completion_percent: number;
};
const dash = "—";
const reactSidebarEnabled = true;
const formatDate = (value: string | null) => value ? new Intl.DateTimeFormat("es-MX", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(`${value.slice(0, 10)}T12:00:00`)) : dash;
function sampleConsecutive(sampleNumber: string) {
    return sampleNumber.match(/-(\d{4})$/)?.[1] || null;
}
export default function Home() {
    const [session, setSession] = useState<Session | null>(null);
    const [authReady, setAuthReady] = useState(false);
    const [authMode, setAuthMode] = useState<"login" | "signup">("login");
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [fullName, setFullName] = useState("");
    const [authMessage, setAuthMessage] = useState("");
    const [authLoading, setAuthLoading] = useState(false);
    const [view, setView] = useState<"entries" | "new" | "clients" | "samples" | "parameters" | "personnel">("entries");
    const [userRole, setUserRole] = useState<AppRole | null>(null);
    const [entries, setEntries] = useState<Entry[]>([]);
    const [query, setQuery] = useState("");
    const [showCancelled, setShowCancelled] = useState(false);
    const [expandedOrderIds, setExpandedOrderIds] = useState<Set<string>>(new Set());
    const [openOrderActionMenuId, setOpenOrderActionMenuId] = useState<string | null>(null);
    const [runningOrderActionId, setRunningOrderActionId] = useState<string | null>(null);
    const [selected, setSelected] = useState<Entry | null>(null);
    const [orderRows, setOrderRows] = useState<OrderRow[]>([]);
    const [sampledInput, setSampledInput] = useState("");
    const [savingOrder, setSavingOrder] = useState(false);
    const [exportConfirmOpen, setExportConfirmOpen] = useState(false);
    const [reportPreviewOpen, setReportPreviewOpen] = useState(false);
    const [exportingReport, setExportingReport] = useState(false);
    const [generatingOrder, setGeneratingOrder] = useState(false);
    const orderTableRef = useRef<HTMLDivElement>(null);
    const orderBottomScrollRef = useRef<HTMLDivElement>(null);
    const [emissionEntry, setEmissionEntry] = useState<Entry | null>(null);
    const [reportInput, setReportInput] = useState("");
    const [issuedInput, setIssuedInput] = useState("");
    const [savingEmission, setSavingEmission] = useState(false);
    const [newClientName, setNewClientName] = useState("");
    const [newClientBranch, setNewClientBranch] = useState("");
    const [newClientContact, setNewClientContact] = useState("");
    const [newClientEmail, setNewClientEmail] = useState("");
    const [newClientPhone, setNewClientPhone] = useState("");
    const [newClientAddress, setNewClientAddress] = useState("");
    const [newClientRfc, setNewClientRfc] = useState("");
    const [newClientAttention, setNewClientAttention] = useState("");
    const [clientSaving, setClientSaving] = useState(false);
    const [clientMessage, setClientMessage] = useState("");
    const [clientDirectory, setClientDirectory] = useState<ClientRecord[]>([]);
    const [clientDirectoryVisible, setClientDirectoryVisible] = useState(true);
    const [expandedClientIds, setExpandedClientIds] = useState<Set<string>>(new Set());
    const [openClientActionMenuId, setOpenClientActionMenuId] = useState<string | null>(null);
    const [deactivatingClientId, setDeactivatingClientId] = useState<string | null>(null);
    const [editingClient, setEditingClient] = useState<ClientRecord | null>(null);
    const [editClientName, setEditClientName] = useState("");
    const [editClientBranch, setEditClientBranch] = useState("");
    const [editClientAddress, setEditClientAddress] = useState("");
    const [editClientContact, setEditClientContact] = useState("");
    const [editClientEmail, setEditClientEmail] = useState("");
    const [editClientRfc, setEditClientRfc] = useState("");
    const [editClientPhone, setEditClientPhone] = useState("");
    const [clientEditSaving, setClientEditSaving] = useState(false);
    const [intakeSubnavVisible, setIntakeSubnavVisible] = useState(false);
    const [clientsSubnavVisible, setClientsSubnavVisible] = useState(false);
    const [parametersSubnavVisible, setParametersSubnavVisible] = useState(false);
    const [parameterDirectoryMode, setParameterDirectoryMode] = useState<"list" | "create">("list");
    const [personnelSubnavVisible, setPersonnelSubnavVisible] = useState(false);
    const [personnelDirectoryMode, setPersonnelDirectoryMode] = useState<"list" | "create">("list");
    const [staffSamples, setStaffSamples] = useState<StaffSample[]>([]);
    const [sampleQuery, setSampleQuery] = useState("");
    async function loadEntries() {
        const { data, error } = await supabase.from("analysis_orders").select("id, op_number, status, sampler_name, quotation_number, received_at, sampled_at, due_date, report_number, issued_at, clients(name, branch, address, rfc, phone, contact_name), samples(id, sample_code, sampling_number, analysis_order_created_at, analysis_label, analysis_packages(code, name))").order("created_at", { ascending: false });
        if (error || !data)
            return;
        setEntries(data.flatMap((item) => {
            const clientData = (Array.isArray(item.clients) ? item.clients[0] : item.clients) as {
                name?: string;
                branch?: string | null;
                address?: string | null;
                rfc?: string | null;
                phone?: string | null;
                contact_name?: string | null;
            } | null;
            return (item.samples || []).map((sample) => {
                const packageData = (Array.isArray(sample.analysis_packages) ? sample.analysis_packages[0] : sample.analysis_packages) as {
                    code?: string;
                    name?: string;
                } | null;
                return { id: item.id, op: item.op_number, client: clientData?.name || dash, clientBranch: clientData?.branch, clientAddress: clientData?.address, clientRfc: clientData?.rfc, clientPhone: clientData?.phone, clientContact: clientData?.contact_name, samplingNumber: sample.sampling_number || dash, sampler: item.sampler_name || dash, quotation: item.quotation_number || dash, received: formatDate(item.received_at), due: formatDate(item.due_date), reportNumber: item.report_number || "", analysis: sample.analysis_label || packageData?.name || packageData?.code || dash, sampleNumber: sample.sample_code, sampleId: sample.id, analysisOrderCreatedAt: sample.analysis_order_created_at || null, sampledAt: item.sampled_at || null, issuedAt: item.issued_at || null, isCancelled: item.status === "cancelada", status: item.status };
            });
        }));
    }
    async function loadClientDirectory() {
        const { data, error } = await supabase.from("clients").select("id, client_number, name, branch, address, contact_name, email, rfc, phone").eq("active", true).order("client_number");
        if (!error && data) setClientDirectory(data as ClientRecord[]);
    }
    function startEditingClient(client: ClientRecord) {
        setEditingClient(client);
        setEditClientName(client.name);
        setEditClientBranch(client.branch || "");
        setEditClientAddress(client.address || "");
        setEditClientContact(client.contact_name || "");
        setEditClientEmail(client.email || "");
        setEditClientRfc(client.rfc || "");
        setEditClientPhone(client.phone || "");
        setClientMessage("");
    }
    function toggleClientDetails(clientId: string) {
        setExpandedClientIds((current) => {
            const next = new Set(current);
            if (next.has(clientId)) next.delete(clientId);
            else next.add(clientId);
            return next;
        });
    }
    async function loadUserRole(activeSession: Session) {
        const { data } = await supabase.from("profiles").select("role").eq("id", activeSession.user.id).maybeSingle();
        const role = data?.role as AppRole | undefined;
        setUserRole(role || null);
        if (role === "analista") setView("samples");
    }
    async function loadStaffSamples() {
        const { data, error } = await supabase.rpc("list_staff_samples");
        if (!error && data) setStaffSamples(data as StaffSample[]);
    }
    useEffect(() => {
        if (reactSidebarEnabled) return;
        if (!session) return;
        const nav = document.querySelector(".sidebar nav");
        if (!nav || document.getElementById("samples-navigation")) return;
        const button = document.createElement("button");
        button.id = "samples-navigation";
        button.className = "nav-item";
        button.textContent = "▤   Muestras";
        button.onclick = () => { setView("samples"); setShowCancelled(false); };
        const clientsButton = document.getElementById("clients-navigation") || [...nav.querySelectorAll("button")].find((item) => item.textContent?.includes("Clientes"));
        if (clientsButton?.nextSibling) nav.insertBefore(button, clientsButton.nextSibling);
        else {
            const firstMuted = nav.querySelector(".muted");
            if (firstMuted) nav.insertBefore(button, firstMuted);
            else nav.append(button);
        }
        return () => button.remove();
    }, [session, userRole, view]);
    useEffect(() => {
        if (reactSidebarEnabled) return;
        if (userRole !== "analista") return;
        const nav = document.querySelector(".sidebar nav");
        if (!nav) return;
        const buttons = [...nav.querySelectorAll("button")];
        buttons.filter((button) => button.id !== "samples-navigation" && !button.classList.contains("muted")).forEach((button) => { button.style.display = "none"; });
    }, [userRole, view]);
    useEffect(() => { supabase.auth.getSession().then(({ data: { session: active } }) => { setSession(active); setAuthReady(true); if (active) void loadUserRole(active); }); const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, active) => { setSession(active); setAuthReady(true); if (active) void loadUserRole(active); else setUserRole(null); }); return () => subscription.unsubscribe(); }, []);
    useEffect(() => {
        if (!openOrderActionMenuId && !openClientActionMenuId) return;
        const closeMenus = () => { setOpenOrderActionMenuId(null); setOpenClientActionMenuId(null); };
        window.addEventListener("click", closeMenus);
        return () => window.removeEventListener("click", closeMenus);
    }, [openOrderActionMenuId, openClientActionMenuId]);
    useEffect(() => { if (!session)
        return; const timer = window.setTimeout(() => { void loadEntries(); }, 0); return () => window.clearTimeout(timer); }, [session]);
    useEffect(() => {
        if (reactSidebarEnabled) return;
        if (!session || userRole === "analista" || view === "clients") return;
        const nav = document.querySelector(".sidebar nav");
        if (!nav || document.getElementById("clients-navigation")) return;
        const button = document.createElement("button");
        button.id = "clients-navigation";
        button.className = "nav-item";
        button.textContent = "▣   Clientes";
        button.onclick = () => { setView("clients"); setClientsSubnavVisible((visible) => !visible); };
        nav.insertBefore(button, nav.children[2] || null);
        return () => button.remove();
    }, [session, userRole, view]);
    useEffect(() => {
        if (reactSidebarEnabled) return;
        if (!session) return;
        const nav = document.querySelector(".sidebar nav");
        if (!nav) return;
        const buttons = [...nav.querySelectorAll("button")];
        const intakeButton = buttons.find((button) => button.textContent?.includes("Entrada de muestras"));
        const cancelledButton = buttons.find((button) => button.textContent?.includes("OPs eliminados"));
        const clientsButton = buttons.find((button) => button.textContent?.includes("Clientes"));
        const directoryButton = document.getElementById("client-directory-navigation");
        if (intakeButton instanceof HTMLButtonElement) {
            if (intakeButton.textContent?.trim() === "Entrada de muestras") intakeButton.textContent = "▦   Entrada de muestras";
            intakeButton.onclick = () => {
                const nextVisible = !intakeSubnavVisible;
                setView("entries"); setShowCancelled(false); setIntakeSubnavVisible(nextVisible);
                if (cancelledButton instanceof HTMLElement) cancelledButton.style.display = nextVisible ? "" : "none";
            };
        }
        if (cancelledButton instanceof HTMLElement) cancelledButton.style.display = intakeSubnavVisible && userRole !== "analista" ? "" : "none";
        if (clientsButton instanceof HTMLButtonElement) {
            if (clientsButton.textContent?.trim() === "Clientes") clientsButton.textContent = "▣   Clientes";
            clientsButton.onclick = () => { setView("clients"); setClientDirectoryVisible(true); setClientsSubnavVisible((visible) => !visible); };
        }
        if (directoryButton instanceof HTMLElement) directoryButton.style.display = clientsSubnavVisible ? "" : "none";
    }, [session, userRole, view, intakeSubnavVisible, clientsSubnavVisible]);
    useEffect(() => {
        if (view !== "clients") return;
        const attentionLabel = [...document.querySelectorAll("label")].find((label) => label.textContent?.trim() === "Atención a");
        attentionLabel?.remove();
    }, [view]);
    useEffect(() => {
        if (reactSidebarEnabled) return;
        if (view !== "clients") return;
        const nav = document.querySelector(".sidebar nav");
        if (!nav || document.getElementById("client-directory-navigation")) return;
        const button = document.createElement("button");
        button.id = "client-directory-navigation";
        button.className = "nav-item nav-subitem";
        button.textContent = "↳ Alta de clientes";
        button.onclick = () => setClientDirectoryVisible(false);
        const clientsButton = document.getElementById("clients-navigation") || [...nav.querySelectorAll("button")].find((item) => item.textContent?.includes("Clientes"));
        if (clientsButton?.nextSibling) nav.insertBefore(button, clientsButton.nextSibling);
        else nav.append(button);
        return () => button.remove();
    }, [view]);
    useEffect(() => {
        if (!session || view !== "clients") return;
        const timer = window.setTimeout(() => { void loadClientDirectory(); }, 0);
        return () => window.clearTimeout(timer);
    }, [session, view]);
    useEffect(() => {
        if (view !== "clients") return;
        async function deactivateClient(client: ClientRecord) {
            setOpenClientActionMenuId(null);
            const confirmed = window.confirm(`¿Seguro que deseas desactivar al cliente ${client.name}${client.branch ? ` - ${client.branch}` : ""}?\n\nYa no estará disponible para nuevas OPs, pero se conservará en todos sus registros históricos.`);
            if (!confirmed) return;
            setClientMessage("");
            setDeactivatingClientId(client.id);
            const { error } = await supabase.from("clients").update({ active: false }).eq("id", client.id);
            setDeactivatingClientId(null);
            if (error) {
                window.alert(`No se pudo desactivar el cliente: ${error.message}`);
                return;
            }
            await loadClientDirectory();
            window.alert(`El cliente ${client.name} fue desactivado.`);
        }
        const form = document.querySelector(".order-form");
        if (!form) return;
        document.getElementById("client-directory")?.remove();
        const section = document.createElement("section"); section.id = "client-directory"; section.className = "table-card";
        const heading = document.createElement("div"); heading.className = "table-toolbar";
        const title = document.createElement("div"); const h2 = document.createElement("h2"); h2.textContent = "Clientes registrados"; const count = document.createElement("p"); count.textContent = `${clientDirectory.length} clientes activos`; title.append(h2, count); heading.append(title);
        const tableWrap = document.createElement("div"); tableWrap.className = "table-wrap"; const table = document.createElement("table"); table.className = "client-table";
        const header = document.createElement("thead"); const headerRow = document.createElement("tr"); ["ID cliente", "Cliente", "Sucursal", "Contacto", "Teléfono", "Acciones", "Detalles"].forEach((label) => { const cell = document.createElement("th"); cell.textContent = label; headerRow.append(cell); }); header.append(headerRow); table.append(header);
        const body = document.createElement("tbody");
        clientDirectory.forEach((client) => {
            const row = document.createElement("tr"); row.className = "client-summary-row";
            [client.client_number.toString(), client.name, client.branch || dash, client.contact_name || dash, client.phone || dash].forEach((value) => { const cell = document.createElement("td"); cell.textContent = value; row.append(cell); });
            const actionCell = document.createElement("td"); const actions = document.createElement("div"); actions.className = "parameter-actions"; actions.onclick = (event) => event.stopPropagation(); const actionButton = document.createElement("button"); actionButton.type = "button"; actionButton.className = "parameter-actions-trigger"; actionButton.textContent = deactivatingClientId === client.id ? "…" : "⋮"; actionButton.disabled = deactivatingClientId === client.id; actionButton.title = `Acciones para ${client.name}`; actionButton.setAttribute("aria-label", actionButton.title); actionButton.setAttribute("aria-haspopup", "menu"); actionButton.setAttribute("aria-expanded", String(openClientActionMenuId === client.id)); actionButton.onclick = () => setOpenClientActionMenuId((current) => current === client.id ? null : client.id); actions.append(actionButton); if (openClientActionMenuId === client.id) { const menu = document.createElement("div"); menu.className = "parameter-actions-menu"; menu.setAttribute("role", "menu"); const editButton = document.createElement("button"); editButton.type = "button"; editButton.textContent = "Modificar"; editButton.setAttribute("role", "menuitem"); editButton.onclick = () => { setOpenClientActionMenuId(null); startEditingClient(client); }; const deactivateButton = document.createElement("button"); deactivateButton.type = "button"; deactivateButton.textContent = "Desactivar"; deactivateButton.className = "parameter-deactivate-action"; deactivateButton.setAttribute("role", "menuitem"); deactivateButton.onclick = () => void deactivateClient(client); menu.append(editButton, deactivateButton); actions.append(menu); } actionCell.append(actions); row.append(actionCell);
            const detailActionCell = document.createElement("td"); const detailButton = document.createElement("button"); const isExpanded = expandedClientIds.has(client.id); detailButton.type = "button"; detailButton.className = "expand-samples client-expand-button"; detailButton.textContent = isExpanded ? "▲" : "▼"; detailButton.title = isExpanded ? "Ocultar detalles" : "Mostrar detalles"; detailButton.setAttribute("aria-label", detailButton.title); detailButton.onclick = () => toggleClientDetails(client.id); detailActionCell.append(detailButton); row.append(detailActionCell); body.append(row);
            if (isExpanded) {
                const detailRow = document.createElement("tr"); detailRow.className = "client-detail-row";
                const detailCell = document.createElement("td"); detailCell.colSpan = 7;
                const details = document.createElement("div"); details.className = "client-detail-grid";
                const detailValues = [["Dirección", client.address || dash], ["Correo electrónico", client.email || dash], ["RFC", client.rfc || dash]];
                detailValues.forEach(([label, value]) => { const item = document.createElement("div"); const caption = document.createElement("span"); caption.textContent = label; const content = document.createElement("strong"); content.textContent = value; item.append(caption, content); details.append(item); });
                detailCell.append(details); detailRow.append(detailCell); body.append(detailRow);
            }
        });
        table.append(body); tableWrap.append(table); section.append(heading, tableWrap); form.append(section);
    }, [view, clientDirectory, expandedClientIds, openClientActionMenuId, deactivatingClientId]);
    useEffect(() => {
        if (view !== "clients") return;
        const form = document.querySelector(".order-form");
        const formCard = form?.querySelector(".form-card") as HTMLElement | null;
        const actions = form?.querySelector(".form-actions") as HTMLElement | null;
        const directory = document.getElementById("client-directory");
        if (formCard) formCard.style.display = clientDirectoryVisible ? "none" : "block";
        if (actions) actions.style.display = clientDirectoryVisible ? "none" : "flex";
        if (directory) directory.style.display = clientDirectoryVisible ? "block" : "none";
    }, [view, clientDirectory, clientDirectoryVisible]);
    useEffect(() => {
        if (reactSidebarEnabled) return;
        if (!session) return;
        const nav = document.querySelector(".sidebar nav");
        if (!nav) return;
        const buttons = [...nav.querySelectorAll("button")];
        const intake = buttons.find((button) => button.textContent?.includes("Entrada de muestras"));
        const cancelled = buttons.find((button) => button.textContent?.includes("OPs eliminados"));
        const clients = buttons.find((button) => button.textContent?.includes("Clientes"));
        const directory = document.getElementById("client-directory-navigation");
        const samples = document.getElementById("samples-navigation");
        const muted = buttons.filter((button) => button.classList.contains("muted"));
        if (intake instanceof HTMLElement) intake.style.display = userRole === "analista" ? "none" : "";
        if (clients instanceof HTMLElement) clients.style.display = userRole === "analista" ? "none" : "";
        if (cancelled instanceof HTMLElement) cancelled.style.display = userRole !== "analista" && intakeSubnavVisible ? "" : "none";
        if (directory instanceof HTMLElement) directory.style.display = clientsSubnavVisible ? "" : "none";
        [intake, cancelled, clients, directory, samples, ...muted].forEach((item) => {
            if (item instanceof HTMLElement) nav.append(item);
        });
    }, [session, userRole, view, intakeSubnavVisible, clientsSubnavVisible, clientDirectoryVisible]);
    useEffect(() => {
        if (view !== "entries" || showCancelled) return;
        const button = document.querySelector(".topbar > .button.primary") as HTMLButtonElement | null;
        if (button) button.textContent = "Nueva OP";
    }, [view, showCancelled]);
    useEffect(() => {
        if (!session || view !== "samples") return;
        const timer = window.setTimeout(() => { void loadStaffSamples(); }, 0);
        return () => window.clearTimeout(timer);
    }, [session, view]);
    useEffect(() => {
        if (reactSidebarEnabled) return;
        const samplesButton = document.getElementById("samples-navigation");
        samplesButton?.classList.toggle("active", view === "samples");
        if (view === "samples") {
            const title = document.querySelector(".topbar h1");
            if (title) title.textContent = "Muestras";
        }
    }, [view, staffSamples]);
    useEffect(() => {
        if (!session) return;
        const nav = document.querySelector(".sidebar nav");
        if (!nav) return;
        const originalItems = [...nav.children] as HTMLElement[];
        originalItems.forEach((item) => { item.style.display = "none"; });
        const menu = document.createElement("div");
        menu.className = "react-sidebar-menu";
        const makeButton = (label: string, className: string, onClick?: () => void) => {
            const button = document.createElement("button");
            button.className = className;
            button.textContent = label;
            if (onClick) button.onclick = onClick;
            return button;
        };
        const items: HTMLButtonElement[] = [];
        if (userRole !== "analista") {
            items.push(makeButton("▦   Entrada de muestras", !showCancelled && view === "entries" ? "nav-item active" : "nav-item", () => {
                setView("entries"); setShowCancelled(false); setIntakeSubnavVisible((visible) => !visible);
            }));
            if (intakeSubnavVisible) items.push(makeButton("↳   OPs eliminados", showCancelled ? "nav-item nav-subitem active" : "nav-item nav-subitem", () => {
                setView("entries"); setShowCancelled(true);
            }));
            items.push(makeButton("▣   Clientes", view === "clients" && clientDirectoryVisible ? "nav-item active" : "nav-item", () => {
                setView("clients"); setClientDirectoryVisible(true); setClientsSubnavVisible((visible) => !visible);
            }));
            if (clientsSubnavVisible) items.push(makeButton("↳   Alta de clientes", view === "clients" && !clientDirectoryVisible ? "nav-item nav-subitem active" : "nav-item nav-subitem", () => {
                setView("clients"); setClientDirectoryVisible(false);
            }));
        }
        items.push(makeButton("▤   Muestras", view === "samples" ? "nav-item active" : "nav-item", () => { setView("samples"); setShowCancelled(false); }));
        if (userRole === "administrador" || userRole === "recepcion") {
            items.push(makeButton("⌁   Parámetros", view === "parameters" && parameterDirectoryMode === "list" ? "nav-item active" : "nav-item", () => {
                setView("parameters"); setParameterDirectoryMode("list"); setShowCancelled(false); setParametersSubnavVisible((visible) => !visible);
            }));
            if (parametersSubnavVisible) items.push(makeButton("↳   Alta de parámetros", view === "parameters" && parameterDirectoryMode === "create" ? "nav-item nav-subitem active" : "nav-item nav-subitem", () => {
                setView("parameters"); setParameterDirectoryMode("create"); setShowCancelled(false);
            }));
        }
        items.push(makeButton("♙   Personal", view === "personnel" && personnelDirectoryMode === "list" ? "nav-item active" : "nav-item", () => {
            setView("personnel"); setPersonnelDirectoryMode("list"); setShowCancelled(false); setPersonnelSubnavVisible((visible) => !visible);
        }));
        if (personnelSubnavVisible && (userRole === "administrador" || userRole === "recepcion")) items.push(makeButton("↳   Alta de personal", view === "personnel" && personnelDirectoryMode === "create" ? "nav-item nav-subitem active" : "nav-item nav-subitem", () => {
            setView("personnel"); setPersonnelDirectoryMode("create"); setShowCancelled(false);
        }));
        items.push(makeButton("◫   Informes", "nav-item muted"));
        items.push(makeButton("▥   Reportes", "nav-item muted"));
        menu.append(...items);
        nav.append(menu);
        return () => {
            menu.remove();
            originalItems.forEach((item) => { item.style.display = ""; });
        };
    }, [session, userRole, view, showCancelled, intakeSubnavVisible, clientsSubnavVisible, clientDirectoryVisible, parametersSubnavVisible, parameterDirectoryMode, personnelSubnavVisible, personnelDirectoryMode]);
    useEffect(() => {
        if (view !== "samples" && view !== "parameters" && view !== "personnel") return;
        const title = document.querySelector(".topbar h1");
        if (title) title.textContent = view === "samples" ? "Muestras" : view === "parameters" ? "Parámetros" : "Personal";
    }, [view]);
    const visibleOrderGroups = useMemo(() => {
        const groups = new Map<string, Entry[]>();
        entries.filter((entry) => showCancelled ? entry.isCancelled : !entry.isCancelled).forEach((entry) => {
            groups.set(entry.id, [...(groups.get(entry.id) || []), entry]);
        });
        return [...groups.entries()].map(([id, orderSamples]): OrderGroup => {
            const samples = [...orderSamples].sort((a, b) => {
                const aConsecutive = sampleConsecutive(a.sampleNumber);
                const bConsecutive = sampleConsecutive(b.sampleNumber);
                if (aConsecutive && bConsecutive) return Number(aConsecutive) - Number(bConsecutive);
                return a.sampleNumber.localeCompare(b.sampleNumber);
            });
            const analyses = [...new Set(samples.map((sample) => sample.analysis))];
            const consecutives = samples.map((sample) => sampleConsecutive(sample.sampleNumber));
            const sampleRange = consecutives.every(Boolean)
                ? consecutives.length === 1 ? consecutives[0]! : `${consecutives[0]} a ${consecutives[consecutives.length - 1]}`
                : samples.length === 1 ? samples[0].sampleNumber : `${samples.length} muestras`;
            return { id, representative: samples[0], samples, analysis: analyses.length === 1 ? analyses[0] : "Varios análisis", sampleRange };
        }).filter((group) => group.samples.some((entry) => `${entry.op} ${entry.client} ${entry.sampleNumber} ${entry.samplingNumber} ${entry.analysis}`.toLowerCase().includes(query.toLowerCase())));
    }, [entries, query, showCancelled]);
    const laboratorySampled = Boolean(selected && !["N/A", dash].includes(selected.samplingNumber.trim().toUpperCase()));
    const worksheetComplete = (!laboratorySampled || Boolean(sampledInput)) && orderRows.length > 0 && orderRows.every((row) => row.uncertainty !== null && row.uncertainty !== "" && Boolean(row.result_value?.trim()) && Boolean(row.analyst_reference?.trim()) && Boolean(row.result_date) && Boolean(row.analyst_name?.trim()) && Boolean(row.released_by?.trim()));
    const visibleStaffSamples = useMemo(() => {
        const normalizedQuery = sampleQuery.trim().toLocaleLowerCase("es-MX");
        if (!normalizedQuery) return staffSamples;
        return staffSamples.filter((sample) => sample.sample_code.toLocaleLowerCase("es-MX").includes(normalizedQuery));
    }, [staffSamples, sampleQuery]);
    const worksheetLocked = selected?.status === "informe_emitido" || Boolean(selected?.reportNumber || selected?.issuedAt);
    async function authenticate(event: React.FormEvent<HTMLFormElement>) { event.preventDefault(); setAuthLoading(true); setAuthMessage(""); const result = authMode === "login" ? await supabase.auth.signInWithPassword({ email, password }) : await supabase.auth.signUp({ email, password, options: { data: { full_name: fullName } } }); setAuthMessage(result.error ? result.error.message : authMode === "login" ? "Acceso correcto." : "Cuenta creada. Revisa tu correo para confirmarla."); setAuthLoading(false); }
    async function openSample(entry: Entry) { setSelected(entry); setExportConfirmOpen(false); setReportPreviewOpen(false); setSampledInput(entry.sampledAt || ""); setOrderRows([]); if (!entry.sampleId)
        return; const { data } = await supabase.from("worksheet_results").select("id, label, unit, row_type, uncertainty, result_value, analyst_reference, analyzed_at, analyst_name, released_by, display_order, par_form, method_reference").eq("sample_id", entry.sampleId).order("display_order"); setOrderRows((data || []).map((row) => ({ ...row, result_date: row.analyzed_at })) as OrderRow[]); }
    function openStaffSample(sample: StaffSample) {
        void openSample({ id: sample.order_id, op: dash, client: dash, samplingNumber: dash, sampler: dash, quotation: dash, received: formatDate(sample.received_at), due: formatDate(sample.due_date), reportNumber: "", analysis: dash, sampleNumber: sample.sample_code, sampleId: sample.sample_id, analysisOrderCreatedAt: sample.analysis_order_created_at, sampledAt: null, issuedAt: null, isCancelled: false });
    }
    async function generateAnalysisOrder() { if (!selected?.sampleId)
        return; setGeneratingOrder(true); const result = await supabase.rpc("create_worksheet_for_sample", { p_sample_id: selected.sampleId }); setGeneratingOrder(false); if (result.error) {
        window.alert(`No se pudo generar la orden: ${result.error.message}`);
        return;
    } await loadEntries(); await openSample({ ...selected, analysisOrderCreatedAt: new Date().toISOString() }); }
    function updateRow(id: string, patch: Partial<OrderRow>) { setOrderRows((rows) => rows.map((row) => row.id === id ? { ...row, ...patch } : row)); }
    function syncHorizontalScroll(source: "table" | "bottom", scrollLeft: number) { const target = source === "table" ? orderBottomScrollRef.current : orderTableRef.current; if (target && Math.abs(target.scrollLeft - scrollLeft) > 1)
        target.scrollLeft = scrollLeft; }
    async function saveAnalysisOrder() { if (!selected)
        return; setSavingOrder(true); const dateResult = userRole === "analista" ? { error: null } : await supabase.from("analysis_orders").update({ sampled_at: sampledInput || null }).eq("id", selected.id); const results = await Promise.all(orderRows.map((row) => supabase.from("analysis_results").update({ uncertainty: row.uncertainty === "" ? null : row.uncertainty, result_value: row.result_value?.trim() || null, analyst_reference: row.analyst_reference?.trim() || null, analyzed_at: row.result_date || null, analyst_name: row.analyst_name?.trim().toUpperCase() || null, released_by: row.released_by?.trim().toUpperCase() || null, updated_at: new Date().toISOString() }).eq("id", row.id))); setSavingOrder(false); const error = dateResult.error || results.find((result) => result.error)?.error; if (error) {
        window.alert(`No se pudo guardar la orden: ${error.message}`);
        return;
    } if (view === "samples") await loadStaffSamples(); else await loadEntries(); setSelected({ ...selected, sampledAt: sampledInput || null }); window.alert("Orden de análisis guardada."); }
    function requestReportExport() {
        if (!selected || orderRows.length === 0) {
            window.alert("La OA no contiene parámetros para exportar.");
            return;
        }
        const missingFields: string[] = [];
        if (laboratorySampled && !sampledInput) missingFields.push("Fecha de muestreo");
        orderRows.forEach((row) => {
            const missing = [row.uncertainty === null || row.uncertainty === "" ? "incertidumbre" : "", !row.result_value?.trim() ? "resultado" : "", !row.analyst_reference?.trim() ? "referencia" : "", !row.result_date ? "fecha" : "", !row.analyst_name?.trim() ? "analista" : "", !row.released_by?.trim() ? "libera" : ""].filter(Boolean);
            if (missing.length) missingFields.push(`${row.label}: ${missing.join(", ")}`);
        });
        if (missingFields.length) {
            window.alert(`Hace falta llenar la OA completamente:\n\n${missingFields.slice(0, 8).join("\n")}${missingFields.length > 8 ? `\n…y ${missingFields.length - 8} campo(s) más.` : ""}`);
            return;
        }
        setExportConfirmOpen(false);
        setReportPreviewOpen(true);
    }
    async function issueReportFromWorksheet() { if (!selected || !worksheetComplete)
        return; setExportingReport(true); const dateResult = await supabase.from("analysis_orders").update({ sampled_at: sampledInput || null }).eq("id", selected.id); const resultUpdates = await Promise.all(orderRows.map((row) => supabase.from("analysis_results").update({ uncertainty: row.uncertainty, result_value: row.result_value?.trim() || null, analyst_reference: row.analyst_reference?.trim() || null, analyzed_at: row.result_date, analyst_name: row.analyst_name?.trim().toUpperCase() || null, released_by: row.released_by?.trim().toUpperCase() || null, updated_at: new Date().toISOString() }).eq("id", row.id))); const saveError = dateResult.error || resultUpdates.find((result) => result.error)?.error; if (saveError) {
        setExportingReport(false);
        window.alert(`No se pudo guardar la orden: ${saveError.message}`);
        return;
    } const { error } = await supabase.rpc("issue_report", { p_order_id: selected.id, p_report_number: null, p_pdf_path: null }); setExportingReport(false); if (error) {
        window.alert(`No se pudo emitir el informe: ${error.message}`);
        return;
    } setExportConfirmOpen(false); setReportPreviewOpen(false); window.alert("La orden de análisis se exportó a informe correctamente."); setSelected(null); await loadEntries(); }
    function openEmission(entry: Entry) { setEmissionEntry(entry); setReportInput(entry.reportNumber); setIssuedInput(entry.issuedAt || ""); }
    async function saveEmission(event: React.FormEvent<HTMLFormElement>) { event.preventDefault(); if (!emissionEntry)
        return; if (!reportInput.trim()) {
        window.alert("El número de informe es obligatorio.");
        return;
    } setSavingEmission(true); const { error } = await supabase.rpc("issue_report", { p_order_id: emissionEntry.id, p_report_number: reportInput.trim(), p_pdf_path: null }); setSavingEmission(false); if (error) {
        window.alert(`No se pudo emitir el informe: ${error.message}`);
        return;
    } setEmissionEntry(null); await loadEntries(); }
    function toggleOrderExpansion(id: string) { setExpandedOrderIds((current) => { const next = new Set(current); if (next.has(id))
        next.delete(id);
    else
        next.add(id); return next; }); }
    async function runOrderAction(orderId: string, action: "cancel_sample_entry" | "restore_sample_entry" | "delete_sample_entry_permanently", confirmation: string) {
        setOpenOrderActionMenuId(null);
        if (!window.confirm(confirmation)) return;
        setRunningOrderActionId(orderId);
        const { error } = await supabase.rpc(action, { p_order_id: orderId });
        setRunningOrderActionId(null);
        if (error) {
            window.alert(error.message);
            return;
        }
        await loadEntries();
    }
    async function createClient(event: React.FormEvent<HTMLFormElement>) {
        event.preventDefault(); setClientSaving(true); setClientMessage("");
        const { data, error } = await supabase.rpc("create_client", { p_name: newClientName, p_contact_name: newClientContact || null, p_email: newClientEmail || null, p_phone: newClientPhone || null, p_address: newClientAddress || null, p_rfc: newClientRfc || null, p_attention_to: newClientAttention || null, p_branch: newClientBranch || null });
        setClientSaving(false);
        if (error) { setClientMessage(`No se pudo guardar: ${error.message}`); return; }
        setClientMessage(`Cliente guardado. Número de cliente: ${data.client_number}`);
        setNewClientName(""); setNewClientBranch(""); setNewClientContact(""); setNewClientEmail(""); setNewClientPhone(""); setNewClientAddress(""); setNewClientRfc(""); setNewClientAttention("");
        await loadClientDirectory();
    }
    function cancelEditingClient() {
        setEditingClient(null);
        setEditClientName("");
        setEditClientBranch("");
        setEditClientAddress("");
        setEditClientContact("");
        setEditClientEmail("");
        setEditClientRfc("");
        setEditClientPhone("");
    }
    async function updateClient(event: React.FormEvent<HTMLFormElement>) {
        event.preventDefault();
        if (!editingClient) return;
        setClientEditSaving(true);
        setClientMessage("");
        const { error } = await supabase.from("clients").update({
            name: editClientName.trim(),
            branch: editClientBranch.trim() || null,
            address: editClientAddress.trim() || null,
            contact_name: editClientContact.trim() || null,
            email: editClientEmail.trim() || null,
            rfc: editClientRfc.trim() || null,
            phone: editClientPhone.trim() || null,
        }).eq("id", editingClient.id);
        setClientEditSaving(false);
        if (error) {
            setClientMessage(error.code === "23505" ? "Ya existe un cliente con ese nombre." : `No se pudo modificar el cliente: ${error.message}`);
            return;
        }
        cancelEditingClient();
        setClientMessage("Cliente modificado correctamente.");
        await loadClientDirectory();
    }
    if (!authReady)
        return <main className="auth-page"><p>Conectando con LabAqua…</p></main>;
    if (view === "clients") return <main className="app-shell">
        <aside className="sidebar">
            <div className="brand"><span>LA</span><div><strong>LabAqua</strong><small>Control de análisis</small></div></div>
            <nav><button className="nav-item" onClick={() => setView("entries")}>Entrada de muestras</button><button className="nav-item active">Clientes</button></nav>
            <button className="user-card" onClick={() => supabase.auth.signOut()}><div className="avatar">{(session?.user.email?.slice(0, 2) || "US").toUpperCase()}</div><div><strong>{session?.user.user_metadata.full_name || "Usuario"}</strong><small>Cerrar sesión</small></div></button>
        </aside>
        <section className="workspace">
            <header className="topbar"><div><p className="eyebrow">LABORATORIO</p><h1>Clientes</h1></div></header>
            <form className="order-form" onSubmit={createClient}>
                <section className="form-card">
                    <h2>Alta de cliente</h2><p>Al guardar se asigna un número único de cliente para usar en nuevas OPs.</p>
                    <div className="form-grid">
                        <label>Nombre o razón social<input required value={newClientName} onChange={(event) => setNewClientName(event.target.value)} /></label>
                        <label>Sucursal<input value={newClientBranch} onChange={(event) => setNewClientBranch(event.target.value)} placeholder="Ej. Planta norte" /></label>
                        <label>Dirección<input value={newClientAddress} onChange={(event) => setNewClientAddress(event.target.value)} /></label>
                        <label>Contacto<input value={newClientContact} onChange={(event) => setNewClientContact(event.target.value)} /></label>
                        <label>Teléfono<input value={newClientPhone} onChange={(event) => setNewClientPhone(event.target.value)} /></label>
                        <label>Correo electrónico<input type="email" value={newClientEmail} onChange={(event) => setNewClientEmail(event.target.value)} /></label>
                        <label>RFC<input value={newClientRfc} onChange={(event) => setNewClientRfc(event.target.value)} /></label>
                    </div>
                    {clientMessage && <p className="auth-message">{clientMessage}</p>}
                </section>
                <div className="form-actions"><button type="button" className="button secondary" onClick={() => setView("entries")}>Cancelar</button><button className="button primary" disabled={clientSaving}>{clientSaving ? "Guardando…" : "Guardar cliente"}</button></div>
            </form>
        </section>
        {editingClient && <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !clientEditSaving) cancelEditingClient(); }}>
            <form className="modal parameter-edit-modal" onSubmit={updateClient}>
                <button type="button" className="close" aria-label="Cerrar" disabled={clientEditSaving} onClick={cancelEditingClient}>×</button>
                <h2>Modificar cliente</h2>
                <p className="client-name">Cliente {editingClient.client_number}: {editingClient.name}</p>
                <div className="parameter-edit-grid">
                    <label>Nombre o razón social<input required value={editClientName} onChange={(event) => setEditClientName(event.target.value)} /></label>
                    <label>Sucursal<input value={editClientBranch} onChange={(event) => setEditClientBranch(event.target.value)} /></label>
                    <label>Dirección<input value={editClientAddress} onChange={(event) => setEditClientAddress(event.target.value)} /></label>
                    <label>Contacto<input value={editClientContact} onChange={(event) => setEditClientContact(event.target.value)} /></label>
                    <label>Teléfono<input value={editClientPhone} onChange={(event) => setEditClientPhone(event.target.value)} /></label>
                    <label>Correo electrónico<input type="email" value={editClientEmail} onChange={(event) => setEditClientEmail(event.target.value)} /></label>
                    <label>RFC<input value={editClientRfc} onChange={(event) => setEditClientRfc(event.target.value)} /></label>
                </div>
                <div className="form-actions"><button type="button" className="button secondary" disabled={clientEditSaving} onClick={cancelEditingClient}>Cancelar</button><button className="button primary" disabled={clientEditSaving}>{clientEditSaving ? "Guardando…" : "Guardar cambios"}</button></div>
            </form>
        </div>}
    </main>;
    if (!session)
        return <main className="auth-page"><section className="auth-card"><div className="auth-brand"><span>LA</span><div><strong>LabAqua</strong><small>Control de análisis</small></div></div><p className="eyebrow">ACCESO INTERNO</p><h1>{authMode === "login" ? "Bienvenido de nuevo" : "Crear cuenta de laboratorio"}</h1><p className="auth-description">{authMode === "login" ? "Ingresa con tu cuenta autorizada." : "Crea la primera cuenta para probar el sistema."}</p><form onSubmit={authenticate} className="auth-form">{authMode === "signup" && <label>Nombre completo<input required value={fullName} onChange={(event) => setFullName(event.target.value)}/></label>}<label>Correo electrónico<input required type="email" value={email} onChange={(event) => setEmail(event.target.value)}/></label><label>Contraseña<input required type="password" minLength={6} value={password} onChange={(event) => setPassword(event.target.value)}/></label>{authMessage && <p className="auth-message">{authMessage}</p>}<button className="button primary full" disabled={authLoading}>{authLoading ? "Procesando…" : authMode === "login" ? "Ingresar" : "Crear cuenta"}</button></form><button className="auth-switch" onClick={() => { setAuthMode(authMode === "login" ? "signup" : "login"); setAuthMessage(""); }}>{authMode === "login" ? "¿No tienes cuenta? Crear cuenta" : "¿Ya tienes cuenta? Iniciar sesión"}</button></section></main>;
    return <main className="app-shell"><aside className="sidebar"><div className="brand"><span>LA</span><div><strong>LabAqua</strong><small>Control de análisis</small></div></div><nav><button className={!showCancelled && view === "entries" ? "nav-item active" : "nav-item"} onClick={() => { setView("entries"); setShowCancelled(false); }}>▦ &nbsp; Entrada de muestras</button><button className={showCancelled ? "nav-item nav-subitem active" : "nav-item nav-subitem"} onClick={() => { setView("entries"); setShowCancelled(true); }}>↳ &nbsp; OPs eliminados</button><button className="nav-item muted">◫ &nbsp; Informes</button><button className="nav-item muted">▥ &nbsp; Reportes</button></nav><button className="user-card" onClick={() => supabase.auth.signOut()}><div className="avatar">{(session.user.email?.slice(0, 2) || "US").toUpperCase()}</div><div><strong>{session.user.user_metadata.full_name || "Usuario"}</strong><small>Cerrar sesión</small></div></button></aside><section className="workspace"><header className="topbar"><div><p className="eyebrow">LABORATORIO</p><h1>{view === "new" ? "Alta de OP y muestra" : showCancelled ? "OPs eliminados" : "Entrada de muestras"}</h1></div>{view === "entries" && !showCancelled && <button className="button primary" onClick={() => setView("new")}>＋ Alta de OP</button>}</header>
    {view === "samples" && <section className="table-card">
      <div className="table-toolbar"><div><h2>Muestras</h2><p>{visibleStaffSamples.length} muestras encontradas</p></div><input type="search" value={sampleQuery} onChange={(event) => setSampleQuery(event.target.value)} placeholder="Buscar número de muestra" aria-label="Buscar por número de muestra" /></div>
      <div className="table-wrap"><table className="intake-table" style={{ width: "820px", minWidth: "820px" }}><thead><tr><th>No. de muestra</th><th>Fecha de entrada</th><th>Fecha compromiso</th><th>Avance</th></tr></thead><tbody>{visibleStaffSamples.length === 0 ? <tr><td colSpan={4}>{sampleQuery.trim() ? "No se encontraron muestras con ese número." : "No hay muestras disponibles."}</td></tr> : visibleStaffSamples.map((sample) => <tr key={sample.sample_id}><td><button className="sample-link" onClick={() => openStaffSample(sample)}>{sample.sample_code}</button></td><td>{formatDate(sample.received_at)}</td><td>{formatDate(sample.due_date)}</td><td><div className="progress-label"><span>{sample.captured_results} de {sample.total_results}</span><b>{sample.completion_percent}%</b></div><div className="progress" aria-label={`${sample.completion_percent}% completado`}><i style={{ width: `${sample.completion_percent}%` }} /></div></td></tr>)}</tbody></table></div>
    </section>}
    {view === "parameters" && <ParameterDirectory canCreate={userRole === "administrador" || userRole === "recepcion"} mode={parameterDirectoryMode} />}
    {view === "personnel" && <PersonnelDirectory canManage={userRole === "administrador" || userRole === "recepcion"} mode={personnelDirectoryMode} userId={session.user.id} />}
    {view === "new" ? <MultiSampleOrderForm onCancel={() => setView("entries")} onCreated={async () => { setView("entries"); await loadEntries(); }} /> : view !== "samples" && view !== "parameters" && view !== "personnel" && <section className="table-card">
      <div className="table-toolbar">
        <div><h2>{showCancelled ? "OPs eliminados" : "Registro de entrada de muestras"}</h2><p>{visibleOrderGroups.length} OPs encontradas</p></div>
        <input aria-label="Buscar entradas" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Buscar OP, cliente o muestra…"/>
      </div>
      <div className="table-wrap"><table className="intake-table entries-table">
        <thead><tr><th>OP</th><th>Cliente</th><th>Análisis</th><th>No. muestra</th><th>Fecha entrada</th><th>No. muestreo</th><th>Muestreador</th><th>Cotización</th><th>Fecha salida</th><th>Informe</th><th>Acciones</th></tr></thead>
        <tbody>{visibleOrderGroups.map((group) => {
          const entry = group.representative;
          const hasMultipleSamples = group.samples.length > 1;
          const expanded = hasMultipleSamples && expandedOrderIds.has(group.id);
          return <Fragment key={group.id}>
            <tr className={entry.isCancelled ? "cancelled-row order-summary-row" : "order-summary-row"}>
              <td><strong>{entry.op}</strong></td>
              <td>{entry.client}</td>
              <td>{hasMultipleSamples ? <div className="analysis-group-cell"><span>{group.analysis}</span><button type="button" className="expand-samples" aria-label={expanded ? `Ocultar muestras de ${entry.op}` : `Mostrar ${group.samples.length} muestras de ${entry.op}`} aria-expanded={expanded} onClick={() => toggleOrderExpansion(group.id)}><span aria-hidden="true">▼</span></button></div> : entry.analysis}</td>
              <td>{hasMultipleSamples ? <span className="sample-range">{group.sampleRange}</span> : <button className="sample-link" onClick={() => void openSample(entry)}>{entry.sampleNumber}</button>}</td>
              <td>{entry.received}</td>
              <td>{entry.samplingNumber}</td>
              <td>{entry.sampler}</td>
              <td>{entry.quotation}</td>
              <td><button className="emission-link" onClick={() => openEmission(entry)}>{formatDate(entry.issuedAt)}</button></td>
              <td><button className="emission-link" onClick={() => openEmission(entry)}>{entry.reportNumber || "Registrar"}</button></td>
              <td><div className="parameter-actions" onClick={(event) => event.stopPropagation()}><button type="button" className="parameter-actions-trigger" aria-label={`Acciones para la OP ${entry.op}`} aria-haspopup="menu" aria-expanded={openOrderActionMenuId === group.id} disabled={runningOrderActionId === group.id} onClick={() => setOpenOrderActionMenuId((current) => current === group.id ? null : group.id)}>{runningOrderActionId === group.id ? "…" : "⋮"}</button>{openOrderActionMenuId === group.id && <div className="parameter-actions-menu order-actions-menu" role="menu">{showCancelled ? <><button type="button" role="menuitem" onClick={() => void runOrderAction(group.id, "restore_sample_entry", `¿Restaurar la OP ${entry.op}?`)}>Restaurar OP</button><button type="button" role="menuitem" className="parameter-deactivate-action" onClick={() => void runOrderAction(group.id, "delete_sample_entry_permanently", `¿Eliminar definitivamente la OP ${entry.op}? Esta acción no se puede deshacer.`)}>Eliminar definitivamente</button></> : <button type="button" role="menuitem" className="parameter-deactivate-action" onClick={() => void runOrderAction(group.id, "cancel_sample_entry", `¿Enviar la OP ${entry.op} a OPs eliminadas?`)}>Eliminar OP</button>}</div>}</div></td>
            </tr>
            {hasMultipleSamples && expanded && group.samples.map((sample, index) => <tr className="sample-child-row" key={sample.sampleId}>
              <td><span className="sample-position">Muestra {index + 1}</span></td>
              <td></td>
              <td>{sample.analysis}</td>
              <td><button className="sample-link" onClick={() => void openSample(sample)}>{sample.sampleNumber}</button></td>
              <td colSpan={7}></td>
            </tr>)}
          </Fragment>;
        })}</tbody>
      </table></div>
    </section>}
  </section>{selected && <div className="modal-backdrop" onClick={() => setSelected(null)}><section className="modal detail-modal" onClick={(event) => event.stopPropagation()}><button className="close" onClick={() => setSelected(null)}>×</button>{selected.analysisOrderCreatedAt && userRole !== "analista" && <button className="button primary oa-export-button" disabled={worksheetLocked || exportingReport} onClick={requestReportExport}>{worksheetLocked ? "Exportada a informe" : "Exportar a Informe"}</button>}<p className="eyebrow">ORDEN DE ANÁLISIS</p>{selected.analysisOrderCreatedAt ? <><div className="detail-grid order-header"><div><span>Número de muestra</span><strong>{selected.sampleNumber}</strong></div><div><span>OP</span><strong>{selected.op}</strong></div><div><span>Paquete de análisis</span><strong>{selected.analysis}</strong></div><label><span>Fecha de muestreo</span><input type="date" value={sampledInput} disabled={worksheetLocked || !laboratorySampled} onChange={(event) => setSampledInput(event.target.value)}/></label><div><span>Fecha de recepción</span><strong>{selected.received}</strong></div><div><span>Fecha compromiso</span><strong>{selected.due}</strong></div></div>{orderRows.length > 0 ? <><div className="order-template" ref={orderTableRef} onScroll={(event) => syncHorizontalScroll("table", event.currentTarget.scrollLeft)}><div className="order-template-head"><span>Incertidumbre</span><span>Prueba</span><span>Resultados</span><span>Unidades</span><span>Referencia analista</span><span>Fecha</span><span>Analista</span><span>Libera</span></div>{orderRows.map((row) => <div className={row.row_type === "aggregate" ? "order-result-row aggregate-row" : "order-result-row"} key={row.id}><input type="number" min="0" step="0.00001" value={row.uncertainty || ""} disabled={worksheetLocked} onChange={(event) => updateRow(row.id, { uncertainty: event.target.value })} placeholder="0.00000"/><div><strong>{row.label}</strong></div><input value={row.result_value || ""} disabled={worksheetLocked} onChange={(event) => updateRow(row.id, { result_value: event.target.value })} placeholder="Resultado"/><span>{row.unit || dash}</span><input inputMode="numeric" maxLength={5} value={row.analyst_reference || ""} disabled={worksheetLocked} onChange={(event) => updateRow(row.id, { analyst_reference: event.target.value.replace(/\D/g, "") })} placeholder="00000"/><input type="date" value={row.result_date || ""} disabled={worksheetLocked} onChange={(event) => updateRow(row.id, { result_date: event.target.value })}/><input maxLength={3} value={row.analyst_name || ""} disabled={worksheetLocked} onChange={(event) => updateRow(row.id, { analyst_name: event.target.value.toUpperCase() })} placeholder="ABC"/><input maxLength={3} value={row.released_by || ""} disabled={worksheetLocked} onChange={(event) => updateRow(row.id, { released_by: event.target.value.toUpperCase() })} placeholder="ABC"/></div>)}</div><div className="order-bottom-scroll" ref={orderBottomScrollRef} onScroll={(event) => syncHorizontalScroll("bottom", event.currentTarget.scrollLeft)}><div /></div></> : <p className="modal-note">Esta orden no tiene aún una plantilla de parámetros.</p>}<button className="button primary full" disabled={savingOrder || worksheetLocked} onClick={() => void saveAnalysisOrder()}>{worksheetLocked ? "Orden exportada a informe" : savingOrder ? "Guardando…" : "Guardar orden de análisis"}</button></> : <><h2>{selected.sampleNumber}</h2><p className="modal-note">Aún no se ha generado la orden de análisis para esta muestra.</p><button className="button primary full" disabled={generatingOrder} onClick={() => void generateAnalysisOrder()}>{generatingOrder ? "Generando…" : "Generar orden de análisis"}</button></>}</section></div>}{selected && reportPreviewOpen && <ReportPreview entry={selected} rows={orderRows} sampledAt={sampledInput} onSampledAtChange={setSampledInput} onClose={() => setReportPreviewOpen(false)} onContinue={() => setExportConfirmOpen(true)} userId={session.user.id}/>} {exportConfirmOpen && <div className="modal-backdrop export-confirm-backdrop" onClick={() => !exportingReport && setExportConfirmOpen(false)}><section className="modal export-confirm-modal" onClick={(event) => event.stopPropagation()}><p className="eyebrow">EXPORTAR A INFORME</p><h2>Confirmar exportación</h2><p className="export-warning">La orden de análisis se exportará a un formato de informe. Ya no podrán modificarse los valores a menos que se comience un proceso de corrección de informe.</p><p className="export-question">¿Está seguro de que quiere exportar a informe?</p><div className="export-confirm-actions"><button className="button secondary" disabled={exportingReport} onClick={() => setExportConfirmOpen(false)}>Cancelar</button><button className="button primary" disabled={exportingReport} onClick={() => void issueReportFromWorksheet()}>{exportingReport ? "Exportando…" : "Sí, exportar a informe"}</button></div></section></div>}{emissionEntry && <div className="modal-backdrop" onClick={() => setEmissionEntry(null)}><section className="modal" onClick={(event) => event.stopPropagation()}><button className="close" onClick={() => setEmissionEntry(null)}>×</button><p className="eyebrow">EMISIÓN DE INFORME</p><h2>{emissionEntry.op}</h2><p className="client-name">{emissionEntry.client} · Muestra {emissionEntry.sampleNumber}</p><form className="auth-form" onSubmit={saveEmission}><label>Número de informe<input value={reportInput} onChange={(event) => setReportInput(event.target.value)} placeholder="Ej. 0001" maxLength={4}/></label><label>Fecha de salida<input type="date" value={issuedInput} onChange={(event) => setIssuedInput(event.target.value)}/></label><button className="button primary full" disabled={savingEmission}>{savingEmission ? "Guardando…" : "Guardar emisión"}</button></form></section></div>}</main>;
}
