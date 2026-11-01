import { describe, expect, test } from "bun:test";
import { type AgentMessage, Tokenizer } from "@oh-my-pi/pi-agent-core";
import type { SessionEntry, SessionMessageEntry } from "@oh-my-pi/pi-agent-core/compaction";
import { foldedToolResultNotice, foldToolResultBodies } from "@oh-my-pi/pi-agent-core/compaction";
import type { AssistantMessage, ToolResultMessage } from "@oh-my-pi/pi-ai";

const tokenizer = new Tokenizer();

let idCounter = 0;
function nextId(): string {
	return `entry-${idCounter++}`;
}

function messageEntry(message: AgentMessage): SessionMessageEntry {
	return { type: "message", id: nextId(), parentId: null, timestamp: new Date(1000).toISOString(), message };
}

function assistantCall(toolName: string, callId: string, args: Record<string, unknown>): AssistantMessage {
	return {
		role: "assistant",
		content: [{ type: "toolCall", id: callId, name: toolName, arguments: args }],
		timestamp: 1000,
		provider: "mock",
		model: "mock",
		api: "mock",
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason: "stop",
	};
}

function toolResult(
	toolName: string,
	callId: string,
	text: string,
	extra?: Partial<ToolResultMessage>,
): ToolResultMessage {
	return {
		role: "toolResult",
		toolCallId: callId,
		toolName,
		content: [{ type: "text", text }],
		isError: false,
		timestamp: 1000,
		...extra,
	};
}

function lines(count: number, prefix = "line"): string {
	return Array.from({ length: count }, (_, i) => `${prefix} ${i + 1}`).join("\n");
}

function compactionEntry(firstKeptEntryId: string): SessionEntry {
	return {
		type: "compaction",
		id: nextId(),
		parentId: null,
		timestamp: new Date(2000).toISOString(),
		summary: "summary",
		firstKeptEntryId,
		tokensBefore: 0,
	} as SessionEntry;
}

function textOf(message: ToolResultMessage): string {
	return message.content.map(block => (block.type === "text" ? block.text : "<image>")).join("");
}

describe("foldToolResultBodies", () => {
	test("folds long tool-result bodies inside [firstKept, compaction) and leaves the rest alone", () => {
		const summarizedRead = toolResult("read", "c0", lines(40, "old"));
		const keptRead = toolResult("read", "c1", lines(40));
		const keptShort = toolResult("bash", "c2", lines(3));
		const liveRead = toolResult("read", "c3", lines(40, "live"));
		const firstKept = messageEntry(assistantCall("read", "c1", { path: "a.py" }));
		const entries: SessionEntry[] = [
			messageEntry(assistantCall("read", "c0", { path: "old.py" })),
			messageEntry(summarizedRead),
			firstKept,
			messageEntry(keptRead),
			messageEntry(assistantCall("bash", "c2", { command: "ls" })),
			messageEntry(keptShort),
		];
		const compaction = compactionEntry(firstKept.id);
		entries.push(compaction, messageEntry(assistantCall("read", "c3", { path: "b.py" })), messageEntry(liveRead));

		const result = foldToolResultBodies(entries, tokenizer, {
			startEntryId: firstKept.id,
			endEntryId: compaction.id,
			maxLines: 5,
		});

		expect(result.prunedCount).toBe(1);
		expect(result.tokensSaved).toBeGreaterThan(0);
		expect(textOf(keptRead)).toBe(`${lines(5)}\n${foldedToolResultNotice(35)}`);
		// Three lines fit the budget; the summarized-away and live results are outside the range.
		expect(textOf(keptShort)).toBe(lines(3));
		expect(textOf(summarizedRead)).toBe(lines(40, "old"));
		expect(textOf(liveRead)).toBe(lines(40, "live"));
		// The fold is not marked as a prune: a later supersede pass may still blank it.
		expect(keptRead.prunedAt).toBeUndefined();

		result.undo();
		expect(textOf(keptRead)).toBe(lines(40));
	});

	test("does not fold when hiding would save only the notice line itself", () => {
		const kept = toolResult("read", "c1", lines(6));
		const firstKept = messageEntry(assistantCall("read", "c1", { path: "a.py" }));
		const entries: SessionEntry[] = [firstKept, messageEntry(kept)];
		const compaction = compactionEntry(firstKept.id);
		entries.push(compaction);
		const result = foldToolResultBodies(entries, tokenizer, {
			startEntryId: firstKept.id,
			endEntryId: compaction.id,
			maxLines: 5,
		});
		expect(result.prunedCount).toBe(0);
		expect(textOf(kept)).toBe(lines(6));
	});

	test("skips errors, already-pruned results, and protected tools", () => {
		const errored = toolResult("bash", "c1", lines(40), { isError: true });
		const pruned = toolResult("read", "c2", lines(40), { prunedAt: 5 });
		const protectedResult = toolResult("read_skill", "c3", lines(40));
		const firstKept = messageEntry(assistantCall("bash", "c1", { command: "x" }));
		const entries: SessionEntry[] = [
			firstKept,
			messageEntry(errored),
			messageEntry(assistantCall("read", "c2", { path: "a.py" })),
			messageEntry(pruned),
			messageEntry(assistantCall("read_skill", "c3", { path: "s.md" })),
			messageEntry(protectedResult),
		];
		const compaction = compactionEntry(firstKept.id);
		entries.push(compaction);
		const result = foldToolResultBodies(entries, tokenizer, {
			startEntryId: firstKept.id,
			endEntryId: compaction.id,
			maxLines: 5,
			protectedTools: ["read_skill"],
		});
		expect(result.prunedCount).toBe(0);
		expect(textOf(errored)).toBe(lines(40));
		expect(textOf(pruned)).toBe(lines(40));
		expect(textOf(protectedResult)).toBe(lines(40));
	});

	test("returns nothing for a missing boundary or a non-positive budget", () => {
		const kept = toolResult("read", "c1", lines(40));
		const firstKept = messageEntry(assistantCall("read", "c1", { path: "a.py" }));
		const entries: SessionEntry[] = [firstKept, messageEntry(kept)];
		const compaction = compactionEntry(firstKept.id);
		entries.push(compaction);
		expect(
			foldToolResultBodies(entries, tokenizer, { startEntryId: "", endEntryId: compaction.id, maxLines: 5 })
				.prunedCount,
		).toBe(0);
		expect(
			foldToolResultBodies(entries, tokenizer, {
				startEntryId: firstKept.id,
				endEntryId: compaction.id,
				maxLines: 0,
			}).prunedCount,
		).toBe(0);
		expect(textOf(kept)).toBe(lines(40));
	});
});
