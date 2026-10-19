/**
 * The working directory of a local ("This computer") mission follows its
 * project. A mission started on its project's default workspace
 * (`local_agents_workspace`, `<root>/<slug>`) runs its next turn in the new
 * project's workspace after a move. A folder the user chose explicitly stays.
 * A turn in progress, or follow-ups already queued for the old folder, keep
 * the folder they were prepared for.
 */
import { localBinding, localRunActive, localWorkspace, rememberBinding, type LocalBinding } from "./localAgents";
import { queuedLocalMessages } from "./localMessageQueue";

const trim = (path: string) => path.replace(/[\\/]+$/, "");
const parent = (path: string) => trim(path).replace(/[\\/][^\\/]*$/, "");

/**
 * Whether `cwd` is some project's default workspace, i.e. a sibling of
 * `workspace` (another project's default folder) under the same root.
 */
export function isProjectWorkspace(cwd: string, workspace: string): boolean {
  const a = trim(cwd), b = trim(workspace);
  return !!a && !!b && a !== parent(a) && parent(a) === parent(b);
}

/** The folder the next turn should use, given the binding and the current project's workspace. */
export function nextTurnFolder(cwd: string, workspace: string): string {
  return trim(cwd) !== trim(workspace) && isProjectWorkspace(cwd, workspace) ? workspace : cwd;
}

/** Nothing is running or waiting for this mission: its folder may change. */
export function folderCanChange(id: string): boolean {
  return !localRunActive(id) && !queuedLocalMessages(id).some(row => row.state !== "accepted");
}

/**
 * The binding to use for the next turn of `id` in `project`: rebinds a
 * default-workspace binding to the project's workspace when the mission
 * moved, and returns the stored binding unchanged otherwise.
 */
export async function followProjectFolder(id: string, project: string, workspace: (slug: string) => Promise<string> = localWorkspace): Promise<LocalBinding | undefined> {
  const binding = localBinding(id);
  if (!binding || !folderCanChange(id)) return binding;
  const target = await workspace(project);
  const cwd = nextTurnFolder(binding.cwd, target);
  if (cwd === binding.cwd) return binding;
  // Re-read: a turn may have started while the workspace was resolved.
  const current = localBinding(id);
  if (!current || current.cwd !== binding.cwd || !folderCanChange(id)) return current;
  const next = { ...current, cwd };
  await rememberBinding(id, next);
  return localBinding(id) ?? next;
}
