import * as fs from "node:fs";
import type { AgentToolResult } from "@oh-my-pi/pi-agent-core";
import type { ToolSession } from ".";
import { cfgReadDedupeUnchanged } from "./settings";

/**
 * `read.dedupeUnchanged`: a re-read of the same resolved file and selector,
 * while the file is unchanged and the earlier full result is still in the live
 * context, answers with a one-line stub instead of the content again.
 *
 * "Unchanged" is all of: the rendered output hash, the file's mtime+size, and the
 * session's per-path mutation counter (bumped by edit/write). "Still in context"
 * asks the session whether the earlier tool result is present and unpruned; a
 * session that cannot answer never gets a stub. Compaction and session switches
 * clear the memory ({@link resetReadDedupe}) — a compaction can fold the kept
 * tail in place without marking it pruned.
 *
 * `;` multi-path reads are never stubbed and never recorded: their parts run as
 * nested calls without their own tool call id.
 */

interface ReadDedupeEntry {
	toolCallId: string;
	seq: number;
	outputHash: bigint;
	mtimeMs: number;
	size: number;
	mutationVersion: number;
}

interface ReadDedupeState {
	seq: number;
	entries: Map<string, ReadDedupeEntry>;
}

/** Per-session cap on tracked keys; the map resets when exceeded. */
const READ_DEDUPE_CAP = 256;

const kReadDedupe = Symbol("read.dedupeUnchanged");

interface SessionWithReadDedupe extends ToolSession {
	[kReadDedupe]?: ReadDedupeState;
}

function state(session: ToolSession): ReadDedupeState {
	const holder = session as SessionWithReadDedupe;
	holder[kReadDedupe] ??= { seq: 0, entries: new Map() };
	return holder[kReadDedupe];
}

/** Forget every earlier read — the content they returned is no longer (verbatim) in context. */
export function resetReadDedupe(session: ToolSession): void {
	const holder = session as SessionWithReadDedupe;
	holder[kReadDedupe]?.entries.clear();
}

function hashContent(content: AgentToolResult<unknown>["content"]): bigint | undefined {
	let hash = BigInt(content.length);
	for (const block of content) {
		if (block.type !== "text") return undefined;
		hash = Bun.hash.wyhash(block.text, hash);
	}
	return hash;
}

/**
 * Record a top-level read, or replace its content with the stub when the same
 * read is already above in context. `resolvedPath` is the absolute file the read
 * rendered (undefined for URLs and other non-file sources: never deduped).
 */
export function applyReadDedupe(
	session: ToolSession,
	toolCallId: string,
	resolvedPath: string | undefined,
	selector: string | undefined,
	displayPath: string,
	result: AgentToolResult<unknown>,
): void {
	if (!cfgReadDedupeUnchanged.get(session.settings)) return;
	const tracker = state(session);
	const seq = ++tracker.seq;
	if (!resolvedPath || result.isError || !session.isToolResultInContext) return;
	const outputHash = hashContent(result.content);
	if (outputHash === undefined || result.content.length === 0) return;
	let stat: fs.Stats;
	try {
		stat = fs.statSync(resolvedPath);
	} catch {
		return;
	}
	const key = `${resolvedPath}\0${selector ?? ""}`;
	const mutationVersion = session.getFileMutationVersion?.(resolvedPath) ?? 0;
	const previous = tracker.entries.get(key);
	if (
		previous &&
		previous.outputHash === outputHash &&
		previous.mtimeMs === stat.mtimeMs &&
		previous.size === stat.size &&
		previous.mutationVersion === mutationVersion &&
		session.isToolResultInContext(previous.toolCallId)
	) {
		const ago = seq - previous.seq;
		result.content = [
			{
				type: "text",
				text: `[${displayPath}: unchanged since your read ${ago} ${ago === 1 ? "call" : "calls"} ago — the content is above in this conversation; read a different range or edit it]`,
			},
		];
		return;
	}
	if (tracker.entries.size >= READ_DEDUPE_CAP) tracker.entries.clear();
	tracker.entries.set(key, { toolCallId, seq, outputHash, mtimeMs: stat.mtimeMs, size: stat.size, mutationVersion });
}
