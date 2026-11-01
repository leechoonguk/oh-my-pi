import * as path from "node:path";
import { getRemoteDir } from "@oh-my-pi/pi-utils";
import type { ToolSession } from "../sdk";
import { findPathVariant, findUniqueWorkspaceSuffix } from "./path-utils";
import { cfgToolsRecoverPathVariants } from "./settings";

// Remote mount path prefix (sshfs mounts) - skip fuzzy matching to avoid hangs
const REMOTE_MOUNT_PREFIX = getRemoteDir() + path.sep;
export function isRemoteMountPath(absolutePath: string): boolean {
	return absolutePath.startsWith(REMOTE_MOUNT_PREFIX);
}
export function isNotFoundError(error: unknown): boolean {
	if (!error || typeof error !== "object") return false;
	const code = (error as { code?: string }).code;
	return code === "ENOENT" || code === "ENOTDIR";
}
/** Per-execute memo of suffix-glob lookups; `null` records a confirmed miss. */
export type SuffixMatchCache = Map<string, { absolutePath: string; displayPath: string; via?: string } | null>;
/**
 * Memoized {@link findUniqueWorkspaceSuffix} for a single read call. A missing
 * path with archive/sqlite extensions probes the workspace once per stage
 * (archive candidates, sqlite candidates, plain path) — each glob carries a
 * 5s timeout, so repeated lookups of the same string stack into a long
 * stall before erroring. The cache collapses repeats within one execute().
 */
export async function findSuffixMatchCached(
	session: ToolSession,
	cache: SuffixMatchCache,
	rawPath: string,
	signal?: AbortSignal,
): Promise<{ absolutePath: string; displayPath: string; via?: string } | null> {
	const hit = cache.get(rawPath);
	if (hit !== undefined) return hit;
	// Lexical variants (`omp/x` → `.omp/x`, repeated cwd prefix) are a few stats
	// and name the exact file; the suffix glob neither reaches dot directories
	// nor a path the cwd basename was prepended to. Opt-in: `tools.recoverPathVariants`.
	const variant = cfgToolsRecoverPathVariants.get(session.settings)
		? await findPathVariant(rawPath, session.cwd)
		: null;
	const result = variant ?? (await findUniqueWorkspaceSuffix(rawPath, session.cwd, signal));
	cache.set(rawPath, result);
	return result;
}
