export type Shape = { [key: string]: true | Shape };
const named = { id: true, name: true } as const;
const team = { ...named, key: true } as const;
export const entities = {
  issue: {
    plural: "issues",
    type: "Issue",
    shape: {
      id: true,
      identifier: true,
      title: true,
      description: true,
      url: true,
      priority: true,
      updatedAt: true,
      team,
      state: named,
      assignee: named,
      project: named,
    },
  },
  project: {
    plural: "projects",
    type: "Project",
    shape: {
      ...named,
      description: true,
      content: true,
      url: true,
      updatedAt: true,
      targetDate: true,
      lead: named,
    },
  },
  comment: {
    plural: "comments",
    type: "Comment",
    shape: {
      id: true,
      body: true,
      url: true,
      updatedAt: true,
      user: named,
      issue: { id: true, identifier: true },
    },
  },
  document: {
    plural: "documents",
    type: "Document",
    shape: {
      id: true,
      title: true,
      content: true,
      url: true,
      updatedAt: true,
      project: named,
    },
  },
  milestone: {
    singular: "projectMilestone",
    plural: "projectMilestones",
    type: "ProjectMilestone",
    shape: { ...named, description: true, targetDate: true, project: named },
  },
  status_update: {
    singular: "projectUpdate",
    plural: "projectUpdates",
    type: "ProjectUpdate",
    shape: {
      id: true,
      body: true,
      health: true,
      url: true,
      updatedAt: true,
      project: named,
    },
  },
  team: { plural: "teams", type: "Team", shape: team },
  user: {
    plural: "users",
    type: "User",
    shape: { ...named, email: true, displayName: true, active: true },
  },
  cycle: {
    plural: "cycles",
    type: "Cycle",
    shape: { ...named, number: true, startsAt: true, endsAt: true, team },
  },
  workflow_state: {
    singular: "workflowState",
    plural: "workflowStates",
    type: "WorkflowState",
    shape: { ...named, type: true, team },
  },
  label: {
    singular: "issueLabel",
    plural: "issueLabels",
    type: "IssueLabel",
    shape: { ...named, color: true, description: true, team },
  },
} satisfies Record<
  string,
  { singular?: string; plural: string; type: string; shape: Shape }
>;
export type Entity = keyof typeof entities;
export function metadata(kind: Entity): {
  singular: string;
  plural: string;
  type: string;
  shape: Shape;
} {
  return { singular: kind, ...entities[kind] };
}
export function selection(shape: Shape): string {
  return Object.entries(shape)
    .map(([k, v]) => (v === true ? k : `${k} { ${selection(v)} }`))
    .join(" ");
}
export function pick(value: any, shape: Shape): any {
  if (value == null) return null;
  return Object.fromEntries(
    Object.entries(shape)
      .filter(([key]) => Object.hasOwn(value, key))
      .map(([key, sub]) => [
        key,
        sub === true ? value[key] : pick(value[key], sub),
      ]),
  );
}
export function display(value: any) {
  const paths: string[] = [];
  let budget = 100_000;
  function visit(v: any, path: string): any {
    if (typeof v === "string") {
      const length = Math.min(8000, Math.max(0, budget));
      budget -= Math.min(length, v.length);
      if (v.length > length) {
        paths.push(path);
        return v.slice(0, length);
      }
      return v;
    }
    if (Array.isArray(v)) return v.map((x, i) => visit(x, `${path}[${i}]`));
    if (v && typeof v === "object")
      return Object.fromEntries(
        Object.entries(v).map(([k, x]) => [
          k,
          visit(x, path ? `${path}.${k}` : k),
        ]),
      );
    return v;
  }
  const data = visit(value, "");
  return {
    data,
    textTruncated: paths.length > 0,
    truncatedFields: paths,
    truncationNotice: paths.length
      ? "Display text was truncated. Patches always fetch the complete body server-side."
      : null,
  };
}
