import { describe, expect, test } from "bun:test";
import * as path from "node:path";

const packageDir = path.join(import.meta.dir, "..", "..");

/** Runs a snippet in a fresh bun process so `APP_NAME` is evaluated against the given env. */
function evalWith(env: Record<string, string | undefined>, code: string): string {
	const proc = Bun.spawnSync([process.execPath, "-e", code], {
		cwd: packageDir,
		env: { ...process.env, PI_FORK_APP_NAME: undefined, ...env },
		stdout: "pipe",
		stderr: "pipe",
	});
	if (proc.exitCode !== 0) throw new Error(proc.stderr.toString());
	return proc.stdout.toString().trim();
}

const NAME = `import { APP_NAME, IS_FORK_BUILD } from "@oh-my-pi/pi-utils"; console.log(APP_NAME, IS_FORK_BUILD);`;

describe("PI_FORK_APP_NAME", () => {
	test("unset keeps the upstream app name and config dir", () => {
		expect(evalWith({}, NAME)).toBe("omp false");
		expect(evalWith({}, `import { CONFIG_DIR_NAME } from "@oh-my-pi/pi-utils"; console.log(CONFIG_DIR_NAME);`)).toBe(
			".omp",
		);
	});

	test("set renames the app but not the config dir", () => {
		expect(evalWith({ PI_FORK_APP_NAME: "omp-local" }, NAME)).toBe("omp-local true");
		expect(
			evalWith(
				{ PI_FORK_APP_NAME: "omp-local" },
				`import { CONFIG_DIR_NAME } from "@oh-my-pi/pi-utils"; console.log(CONFIG_DIR_NAME);`,
			),
		).toBe(".omp");
	});

	test("a fork build refuses to self-update from the omp release channel", () => {
		const out = evalWith(
			{ PI_FORK_APP_NAME: "omp-local" },
			`import { runUpdateCommand } from "./src/cli/update-cli"; await runUpdateCommand({ force: false, check: true });`,
		);
		expect(out).toContain("omp-local is a fork build");
	});
});
